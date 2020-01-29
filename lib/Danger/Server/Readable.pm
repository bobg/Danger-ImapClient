# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Readable;

use base qw(Danger::Server::Thing);

use Danger::Error;
use Errno qw(EINTR EAGAIN EWOULDBLOCK);
use IO::Wrap;

@Danger::Server::ReadError::ISA = qw(Danger::Error);

sub configure {
  my($self, $fh, $consume_fn, $eof_fn) = @_;

  $fh = &wraphandle($fh);
  my $buffer = '';

  $self->SUPER::configure(read_buffer => \$buffer,
                          consume_fn  => $consume_fn,
                          eof_fn      => $eof_fn,
                          read_fh     => $fh);
}

sub consume_fn     { shift->_field(consume_fn     => @_) }
sub eof_fn         { shift->_field(eof_fn         => @_) }
sub read_buffer    { shift->_field(read_buffer    => @_) }
sub read_fh        { shift->_field(read_fh        => @_) }
sub repeat_consume { shift->_field(repeat_consume => @_) }

# call this only when select(2) says there's data ready
sub do_read {
  my($self, $ready) = @_;

  $self->repeat_consume(0);

  my $nbytes;
  my $bufptr = $self->read_buffer();
  if ($ready && defined(my $fh = $self->read_fh())) {
    $nbytes = $fh->sysread($$bufptr, 32768, length($$bufptr));
    if (!defined($nbytes)
	&& ($! != EINTR)
	&& ($! != EAGAIN)
	&& ($! != EWOULDBLOCK)) {
      throw Danger::Server::ReadError(errno    => $!,
				      errstr   => "$!",
				      readable => $self);
    }
  }
  my $eof = ($ready && defined($nbytes) && ($nbytes == 0));
  if (!$ready || (defined($nbytes) && length($$bufptr))) {
    my $consume_fn = $self->consume_fn();
    &$consume_fn($self, $bufptr, $eof);
  }
  if ($eof) {
    $self->repeat_consume(0);
    if (defined(my $eof_fn = $self->eof_fn())) {
      &$eof_fn($self);
    } else {
      $self->close();
    }
  }
  return $nbytes;
}

sub close {
  my $self = shift;
  my $fh = delete $self->{read_fh};
  $fh->close() if defined($fh);
}

1;
