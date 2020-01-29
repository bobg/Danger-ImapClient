# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

our $danger_home;

BEGIN {
  $danger_home = $ENV{DANGER_HOME};
  $danger_home ||= '/danger';
}

package Danger::Server;

use base qw(Danger::Server::Thing);

use Danger::Error;
use Danger::Logger qw(logf set_log_level);
use Danger::Server::Child;
use Errno qw(EEXIST);
use File::Basename;
use File::Path;
use IO::File;
use IO::Socket::INET;
use POSIX qw(:sys_wait_h _exit);
use Sys::Hostname;

sub configure {
  my $self = shift;
  my $name = shift;

  $self->SUPER::configure(name        => $name,
                          readers     => [],
                          writers     => [],
                          listeners   => [],
                          children    => [],
                          connections => [],
                          timers      => [],
                          reapable    => [],
                          callbacks   => {},
                          @_);
}

sub name { shift->_field(name => @_) }

sub children    { @{shift->{children}} }
sub connections { @{shift->{connections}} }
sub listeners   { @{shift->{listeners}} }
sub readers     { @{shift->{readers}} }
sub reapable    { @{shift->{reapable}} }
sub timers      { @{shift->{timers}} }
sub writers     { @{shift->{writers}} }

sub exit_loop { shift->{exit_loop} = 1 }

# convenience feature: "available children" list
sub child_consume      { shift->_field(child_consume      => @_) }
sub child_eof          { shift->_field(child_eof          => @_) }
sub child_fn           { shift->_field(child_fn           => @_) }
sub kill_child_fn      { shift->_field(kill_child_fn      => @_) }
sub max_children       { shift->_field(max_children       => @_) }
sub max_spare_children { shift->_field(max_spare_children => @_) }
sub min_spare_children { shift->_field(min_spare_children => @_) }

sub available_child {
  my $self = shift;

  $self->{available_children} ||= [];

  while ((@{$self->{available_children}} < $self->min_spare_children())
         && ($self->children() < $self->max_children())) {
    # override new_child
    my $new_child = $self->new_child();
    unshift(@{$self->{available_children}}, $new_child);
  }

  return undef if !@{$self->{available_children}};

  my $result = shift(@{$self->{available_children}});

  # xxx spawn back up to min_spare_children?

  return $result;
}

sub make_child_available {
  my($self, $child) = @_;       # $child must be a child of $self

  $self->{available_children} ||= [];

  unshift(@{$self->{available_children}}, $child);

  while (@{$self->{available_children}} > $self->max_spare_children()) {
    my $child = pop(@{$self->{available_children}});
    # override kill_child
    $self->kill_child($child);
  }
}

sub kill_child {
  my($self, $child) = @_;

  if (defined(my $kill_child_fn = $self->kill_child_fn())) {
    &$kill_child_fn($self, $child);
  } else {
    # the default, gentle way to kill a child
    $child->close_pipe_to_child();
  }
}

sub new_child {
  my $self = shift;

  return new Danger::Server::Child($self,
                                   $self->child_consume(),
                                   $self->child_eof(),
                                   $self->child_fn());
}

# $timeout -- max seconds to wait in select
sub iterate {
  my($self, $timeout) = @_;

  $self->{exit_loop} = 0;

  my @reapable = $self->reapable();
  foreach my $child (@reapable) {
    my $pid = $child->pid();
    my $res = waitpid($pid, WNOHANG);
    if ($res == $pid) {
      $self->{reapable} = [grep { $_->pid() != $pid } $self->reapable()];
      $child->reaped($?);
    }
  }

  $self->call_callbacks('top_of_loop');
  return if $self->{exit_loop};

  foreach my $timer ($self->timers()) {
    $timer->maybe_trigger();
  }
  return if $self->{exit_loop};

  my $r = '';
  my $w = '';
  my $repeats = 0;

  foreach my $reader ($self->readers()) {
    if ($reader->repeat_consume()) {
      ++$repeats;
    } else {
      my $fh = $reader->read_fh();
      vec($r, $fh->fileno(), 1) = 1;
    }
  }
  foreach my $writer ($self->writers()) {
    if ($writer->write_data_p()) {
      my $fh = $writer->write_fh();
      vec($w, $fh->fileno(), 1) = 1;
    }
  }
  foreach my $listener ($self->listeners()) {
    my $socket = $listener->socket();
    vec($r, $socket->fileno(), 1) = 1;
  }
  foreach my $child ($self->children()) {
    if (defined(my $pipe_to_child = $child->pipe_to_child())) {
      if ($child->write_data_p()) {
        vec($w, $pipe_to_child->fileno(), 1) = 1;
      }
    }
    if ($child->repeat_consume()) {
      ++$repeats;
    } elsif (defined(my $pipe_from_child = $child->pipe_from_child())) {
      vec($r, $pipe_from_child->fileno(), 1) = 1;
    }
  }
  foreach my $connection ($self->connections()) {
    my $socket = $connection->socket();
    if ($connection->connecting() || $connection->write_data_p()) {
      vec($w, $socket->fileno(), 1) = 1;
    }
    if (!$connection->connecting()) {
      if ($connection->repeat_consume()) {
	++$repeats;
      } else {
	vec($r, $socket->fileno(), 1) = 1;
      }
    }
  }

  # my $e = $r | $w;
  my $e = '';

  $timeout += time if defined($timeout);
  foreach my $timer ($self->timers()) {
    my $when = $timer->when();
    if (!defined($timeout) || ($when < $timeout)) {
      $timeout = $when;
    }
  }
  if (defined($timeout)) {
    $timeout -= time;
    $timeout = 0 if ($timeout < 0);
  }

  $self->call_callbacks('pre_select', $timeout);
  return if $self->{exit_loop};

  my $nfound = 0;
  if (defined($timeout) || ($r ne '') || ($w ne '')) {
    $nfound = select($r, $w, $e, $timeout);
  }

  $self->call_callbacks('post_select', $nfound);
  return if $self->{exit_loop};

  if ($nfound || $repeats) {
    foreach my $reader ($self->readers()) {
      my $fh = $reader->read_fh();
      next unless defined($fh); # if a callback closed it since the loop began

      my $fileno = $fh->fileno();
      if (vec($e, $fileno, 1)) {
        &logf(LOG_DEBUG2 => 0,
              'Exception on readable %d',
              $fileno);
      }
      my $ready = vec($r, $fileno, 1);
      if ($reader->repeat_consume() || $ready) {
        $reader->do_read($ready);
      }
    }
    foreach my $writer ($self->writers()) {
      my $fh = $writer->write_fh();
      next unless defined($fh); # if a callback closed it since the loop began

      my $fileno = $fh->fileno();
      if (vec($e, $fileno, 1)) {
        &logf(LOG_DEBUG2 => 0,
              'Exception on writable %d',
              $fileno);
      }
      if (vec($w, $fileno, 1)) {
        $writer->do_write();
      }
    }
    foreach my $listener ($self->listeners()) {
      my $socket = $listener->socket();
      next unless defined($socket);

      my $fileno = $socket->fileno();
      if (vec($e, $fileno, 1)) {
        &logf(LOG_DEBUG2 => 0,
              'Exception on listener %d',
              $fileno);
      }
      if (vec($r, $socket->fileno(), 1)) {
        $listener->accept();
      }
    }
    foreach my $child ($self->children()) {
      my $pid = $child->pid();
      if (defined(my $pipe_to_child = $child->pipe_to_child())) {
        my $fileno = $pipe_to_child->fileno();
        if (vec($e, $fileno, 1)) {
          &logf(LOG_DEBUG2 => 0,
                'Exception on pipe %d to child %d',
                $fileno, $pid);
        }
        if (vec($w, $pipe_to_child->fileno(), 1)) {
          $child->do_write();
        }
      }

      my $pipe_from_child = $child->pipe_from_child();
      if ($child->repeat_consume() || defined($pipe_from_child)) {
        my $fileno;
        if (defined($pipe_from_child)) {
          $fileno = $pipe_from_child->fileno();
        }
        if (defined($fileno) && vec($e, $fileno, 1)) {
          &logf(LOG_DEBUG2 => 0,
                'Exception on pipe %d from child %d',
                $fileno, $pid);
        }
        my $ready = (defined($fileno) && vec($r, $fileno, 1));
        if ($child->repeat_consume() || $ready) {
          $child->do_read($ready);
        }
      }
    }
    foreach my $connection ($self->connections()) {
      my $socket = $connection->socket();
      next unless defined($socket);

      my $fileno = $socket->fileno();

      if (!defined($fileno)) {
        &logf(LOG_WARN => 0,
              "Whoa, fileno not defined?  Connection is:\n%D",
              $connection);
      } else {
        if (vec($e, $fileno, 1)) {
          &logf(LOG_DEBUG2 => 0,
                'Exception on connection %d',
                $fileno);
        }
        if (vec($w, $fileno, 1)) {
          if ($connection->connecting()) {
            my $err = $socket->sockopt(SO_ERROR);

            if ($err == 0) {
              $connection->complete();
            } else {
              $connection->fail($err);
            }
          } else {
            $connection->do_write();
          }
        }
	# Note: socket might have been closed in do_write
	# (detect this with defined($socket->fileno()))
        my $ready = (vec($r, $fileno, 1) && defined($socket->fileno()));
        if ($connection->repeat_consume() || $ready) {
          $connection->do_read($ready);
        }
      }
    }
  }
}

sub open_fds {
  my $self = shift;

  my %result;

  foreach my $reader ($self->readers()) {
    my $fh = $reader->read_fh();
    $result{$fh->fileno()} = 1;
  }
  foreach my $writer ($self->writers()) {
    my $fh = $writer->write_fh();
    $result{$fh->fileno()} = 1;
  }
  foreach my $listener ($self->listeners()) {
    my $socket = $listener->socket();
    $result{$socket->fileno()} = 1;
  }
  foreach my $child ($self->children()) {
    if (defined(my $pipe_to_child = $child->pipe_to_child())) {
      $result{$pipe_to_child->fileno()} = 1;
    }
    if (defined(my $pipe_from_child = $child->pipe_from_child())) {
      $result{$pipe_from_child->fileno()} = 1;
    }
  }
  foreach my $connection ($self->connections()) {
    my $socket = $connection->socket();
    $result{$socket->fileno()} = 1;
  }
  return keys %result;
}

sub run {
  my $self = shift;

  $self->{exit_loop} = 0;

  while (!$self->{exit_loop}) {
    $self->iterate();
  }
}

sub add_callback {
  my($self, $name, $fn) = @_;

  $self->{callbacks}->{$name} ||= [];
  push(@{$self->{callbacks}->{$name}}, $fn);
}

sub call_callbacks {
  my $self = shift;
  my $name = shift;

  my $callbacks = $self->{callbacks}->{$name};

  if (defined($callbacks)) {
    foreach my $callback (@$callbacks) {
      &$callback($self, @_);
    }
  }
}

sub add_reader {
  my($self, $reader) = @_;

  push(@{$self->{readers}}, $reader);
}

sub add_writer {
  my($self, $writer) = @_;

  push(@{$self->{writers}}, $writer);
}

sub add_child {
  my($self, $child) = @_;

  push(@{$self->{children}}, $child);
}

sub add_connection {
  my($self, $connection) = @_;

  push(@{$self->{connections}}, $connection);
}

sub remove_connection {
  my($self, $connection) = @_;

  $self->{connections} = [grep { $_ ne $connection } $self->connections()];
}

sub add_listener {
  my($self, $listener) = @_;

  push(@{$self->{listeners}}, $listener);
}

sub remove_listener {
  my($self, $listener) = @_;

  $self->{listeners} = [grep { $_ ne $listener } $self->listeners()];
}

sub add_timer {
  my($self, $timer) = @_;

  push(@{$self->{timers}}, $timer);
}

sub remove_timer {
  my($self, $timer) = @_;

  $self->{timers} = [grep { $_ ne $timer } $self->timers()];
}

sub remove_reader {
  my($self, $reader) = @_;

  $self->{readers} = [grep { $_ ne $reader } $self->readers()];
}

sub remove_writer {
  my($self, $writer) = @_;

  $self->{writers} = [grep { $_ ne $writer } $self->writers()];
}

sub remove_child {
  my($self, $child) = @_;

  $self->{children} = [grep { $_ ne $child } $self->children()];

  if ($self->{available_children}) {
    $self->{available_children} =
        [grep { $_ ne $child } @{$self->{available_children}}];
    # xxx spawn back up to min_spare_children?
  }
}

sub add_reapable {
  my($self, $child) = @_;

  push(@{$self->{reapable}}, $child);
}

############################################################

# convenience functions

# place the calling process in the background
sub background {
  close(STDIN);
  my $res = fork;
  if (!defined($res)) {
    # xxx error
  }
  if ($res) {
    &POSIX::_exit(0);
  }
}

# start logging in the conventional Danger way
sub start_logging {
  my $first_arg = shift;

  my $logname;
  if (ref($first_arg)) {
    $logname = shift;
  } else {
    $logname = $first_arg;
  }
  my($log_level, $logdir, $stderr) = @_;

  if (!defined($logdir)) {
    $logdir = "$danger_home/logs";
  }
  if (!defined($log_level)) {
    $log_level = 'LOG_DEBUG';
  }

  if (!$stderr) {
    my $short_hostname = &hostname();
    $short_hostname =~ s/\..*//;

    my $logfile = sprintf('%s/error.%s.%s',
                          $logdir, $logname, $short_hostname);
    open(STDERR, sprintf('| %s/local/sbin/rotolog -ld %s',
                         $danger_home, $logfile));
  }

  &set_log_level($log_level);

  &logf(LOG_INFO => 0, 'Started %s logging at level %s',
        $logname, $log_level);
}

@Danger::Server::PidfileError::ISA = qw(Danger::Error);

sub pidfile {
  my $pidfile = shift;
  $pidfile = shift if ref($pidfile);

  if ($pidfile !~ m|^/|) {
    $pidfile = "$danger_home/run/$pidfile";
  }

  my $pidfile_dir = &dirname($pidfile);
  &mkpath($pidfile_dir);

  my $tries = (shift or 3);

  for (my $i = 0; $i < $tries; ++$i) {
    my $pidfh = new IO::File($pidfile, O_WRONLY|O_EXCL|O_CREAT);
    if (defined($pidfh)) {
      $pidfh->print("$$\n");
      $pidfh->close();
      return 0;
    }
    if ($! == EEXIST) {
      $pidfh = new IO::File("<$pidfile");
      if (!defined($pidfh)) {
        throw Danger::Server::PidfileError(pidfile => $pidfile,
                                           errno   => $!,
                                           errstr  => "$!");
      }
      my $pid = $pidfh->getline();
      chomp $pid;
      $pidfh->close();
      if ($pid) {
        if (kill(0, $pid)) {
          return $pid;
        }
        warn "Removing stale pidfile $pidfile\n"; # xxx verbose option?
        unlink $pidfile;
        next;
      }
      warn "Removing malformed pidfile\n"; # xxx verbose option?
      unlink $pidfile;
      next;
    }
    throw Danger::Server::PidfileError(pidfile => $pidfile,
                                       errno   => $!,
                                       errstr  => "$!");
  }
  throw Danger::Server::PidfileError(pidfile => $pidfile,
                                     tries   => $tries);
}

1;

__END__

=head1 NAME

Danger::Server - Flexible server framework

=head1 SYNOPSIS

  use Danger::Server;

  my $server = new Danger::Server();

  # ...set up listeners, callbacks, etc...

  $server->run();

=head1 DESCRIPTION

Danger::Server is a server framework specializing in non-blocking I/O for
highly asynchronous operation even when operating in a single thread of
execution.

=head1 METHODS

=over

=item new Danger::Server($name)

Create a new server named C<$name>.

=item $server->run()

=item $server->iterate()

=item $server->exit_loop()

=item $server->background()

=item $server->start_logging($logname[, $log_level[, $log_dir]])

Start appending STDERR using C<rotolog> to a log file with the root name
C<"$log_dir/error.$logname.$short_hostname">.  (The rest of the name is
supplied by rotolog and corresponds to the current date.)  The libdanger log
level is set to C<$log_level>, which defaults to C<LOG_DEBUG>.  The default
for C<$log_dir> is C<"/danger/logs">.

=item $server->children()

Returns the list of pending server children as C<Danger::Server::Child> (or
subclass) objects.

=item $server->reapable()

=item $server->connections()

Returns the list of pending server TCP connections as
C<Danger::Server::Connection> (or subclass) objects.

=item $server->listeners()

=item $server->readers()

=item $server->writers()

=item $server->timers()

=item $server->child_consume([$fn])

=item $server->child_eof([$fn])

=item $server->child_fn([$fn])

=item $server->max_children([$max])

=item $server->max_spare_children([$max])

=item $server->min_spare_children([$min])

=item $server->available_child()

=item $server->make_child_available($child)

=item $server->new_child()

=back

=head1 TO DO

=head1 SEE ALSO

L<Danger::Server::Child>, L<Danger::Server::Connection>,
L<Danger::Server::Listener>, L<Danger::Server::Reader>,
L<Danger::Server::Writer>, L<Danger::Server::Timer>
