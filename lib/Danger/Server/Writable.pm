# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Writable;

use base qw(Danger::Server::Thing);

use Danger::Error;
use Danger::Logger qw(logf);
use Errno qw(EINTR EAGAIN EWOULDBLOCK EPIPE);
use IO::Wrap;

@Danger::Server::WriteError::ISA = qw(Danger::Error);
@Danger::Server::NothingWrittenError::ISA = qw(Danger::Error);

use constant MAX_EINTR_RETRIES => 5;

sub configure {
  my($self, $fh) = @_;

  $fh = &wraphandle($fh);

  $self->SUPER::configure(write_fh    => $fh,
                          write_queue => []);
}

sub epipe_handler { shift->_field(epipe_handler => @_) }
sub write_fh      { shift->_field(write_fh      => @_) }
sub write_queue   { shift->_field(write_queue   => @_) }

# call this only when select(2) says it's ready for data
sub do_write {
  my $self = shift;
  my $fh = $self->write_fh();
  my $queue = $self->write_queue();
  my $total_written = 0;
  my $handled;
  my $eintr_retries = 0;
  while (1) {
    last unless @$queue;
    my $elt = $queue->[0];
    if (ref($elt)) {
      shift @$queue;
      &$elt($self);
    } elsif (my $to_write = length($elt)) {
      $to_write = 8192 if ($to_write > 8192);
      my $written = $fh->syswrite($elt, $to_write);
      if (!defined($written)) {
        if ($! == EINTR) {
          if (++$eintr_retries > MAX_EINTR_RETRIES) {
            &logf(LOG_DEBUG2 => 0,
                  'Too many EINTR retries in do_write()');
            last;
          }
          next;
        }
        last if $! == EAGAIN;
        last if $! == EWOULDBLOCK;

        if (($! == EPIPE)
            && defined(my $handler = $self->epipe_handler())) {
            &$handler($self);
            $handled = 1;
          last;
        }

        throw Danger::Server::WriteError(errno    => $!,
                                         errstr   => "$!",
                                         writable => $self);

      } else {
        $eintr_retries = 0;
        $total_written += $written;
        if ($written == length($elt)) {
          shift @$queue;
        } elsif ($written > 0) {
          $queue->[0] = substr($queue->[0], $written);
        } else {
          last;
        }
      }
      } else {
      shift @$queue;
    }
  }
  if (($total_written == 0) && !$handled) {
    throw Danger::Server::NothingWrittenError(writable => $self);
  }
  return $total_written;
}

sub write_data_p {
  my $self = shift;

  foreach my $elt (@{$self->{write_queue}}) {
    return 1 if (!ref($elt) && length($elt));
  }
  return undef;
}

sub write {
  my $self = shift;

  my $queue = $self->write_queue();

  foreach my $elt (@_) {
    if (ref($elt)) {
      if (@$queue) {
        push(@$queue, $elt);
      } else {
        # don't allow callbacks to appear at the front of the write queue;
        # call them immediately instead
        &$elt($self);
      }
    } elsif (length($elt)) {
      if (@$queue && !ref($queue->[$#$queue])) {
        $queue->[$#$queue] .= $elt;
      } else {
        push(@$queue, $elt);
      }
    }
  }
}

sub close {
  my($self, $immediate) = @_;

  if ($immediate) {
    my $fh = delete $self->{write_fh};
    $fh->close() if defined($fh);
  } else {
    # schedule an immediate close after pending output has drained
    $self->write(sub { $self->close(1) });
  }
}

1;
