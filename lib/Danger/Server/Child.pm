# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Child;

use base qw(Danger::Server::Readable Danger::Server::Writable);

use Danger::Error;
use IO::Pipe;
use POSIX;

@Danger::Server::ForkError::ISA = qw(Danger::Error);

sub new {
  my($type, $server, $consume_fn, $eof_fn, $child_fn,
      @hold_open) = @_;

  my $pipe_to_child = new IO::Pipe();
  my $pipe_from_child = new IO::Pipe();

  my $pid = fork;

  if (!defined($pid)) {
    throw Danger::Server::ForkError(server => $server,
                                    errno  => $!,
                                    errstr => "$!");
  }

  my @fds = $server->open_fds();

  if ($pid == 0) {
    # CHILD
    $pipe_to_child->reader();
    $pipe_from_child->writer();

    my $pipe_to_child_fd   = $pipe_to_child->fileno();
    my $pipe_from_child_fd = $pipe_from_child->fileno();

    foreach my $fd (@fds) {
      next if ($fd < 3);        # leave stdin, stdout, stderr open
      next if ($fd == $pipe_to_child_fd);
      next if ($fd == $pipe_from_child_fd);
      next if grep { $_ == $fd } @hold_open;
      &POSIX::close($fd);
    }

    &$child_fn($pipe_to_child, $pipe_from_child);
    exit(0);
    die "exit(0) failed!";
  }

  # PARENT
  $pipe_to_child->writer();
  $pipe_to_child->blocking(0);
  $pipe_to_child->autoflush(1);

  $pipe_from_child->reader();
  $pipe_from_child->blocking(0);

  my $self = new Danger::Server::Readable($pipe_from_child,
					  $consume_fn, $eof_fn);
  bless $self, $type;

  $self->Danger::Server::Writable::configure($pipe_to_child);

  $self->{pid}    = $pid;
  $self->{server} = $server;

  $server->add_child($self);

  return $self;
}

sub pid             { shift->_field(pid => @_) }
sub pipe_from_child { shift->read_fh() }
sub pipe_to_child   { shift->write_fh() }
sub server          { shift->_field(server => @_) }

sub close_pipe_to_child {
  my($self, $immediate) = @_;

  if ($immediate) {
    $self->Danger::Server::Writable::close(1);
    delete $self->{pipe_to_child};
  } else {
    $self->write(sub { $self->close_pipe_to_child(1) });
  }
}

sub close_pipe_from_child {
  my $self = shift;

  $self->Danger::Server::Readable::close();
  delete $self->{pipe_from_child};
}

sub reap {
  my($self, $reap_fn) = @_;

  $self->close_pipe_from_child();
  $self->close_pipe_to_child(1);

  my $server = $self->server();

  $server->remove_child($self);
  $server->add_reapable($self);

  $self->{reap_fn} = $reap_fn;
}

sub reaped {
  my($self, $status) = @_;

  if (defined(my $reap_fn = $self->{reap_fn})) {
    &$reap_fn($self, $status);
  }
}

sub kill {
  my($self, $sig) = @_;

  kill($sig, $self->pid());
}

1;
