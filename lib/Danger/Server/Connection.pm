# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Connection;

use base qw(Danger::Server::Readable Danger::Server::Writable);

use Danger::Error;
use Errno qw(EINPROGRESS);
use IO::Socket::INET;

@Danger::Server::ConnectError::ISA = qw(Danger::Error);

sub new {
  my $type = shift;

  my $self = {};
  bless $self, $type;

  $self->configure(@_);

  return $self;
}

sub configure {
  my($self, $server, %args) = @_;

  my $consume_fn  = $args{consume_fn};
  my $complete_fn = $args{complete_fn};
  my $eof_fn      = $args{eof_fn};
  my $fail_fn     = $args{fail_fn};
  my $host        = $args{host};
  my $port        = $args{port};
  my $socket      = $args{socket};
  my $timeout     = $args{timeout};

  my $call_complete;

  if (defined($socket)) {
    $self->connecting(0);
  } else {
    # xxx check host/port
    $socket = new IO::Socket::INET(PeerHost => $host,
				   PeerPort => $port,
				   Timeout  => $timeout,
				   Blocking => 0,
				   Proto    => 'tcp',
				   Reuse    => 1);
    if (!defined($socket)) {
      throw Danger::Server::ConnectError(errno      => $!,
					 errstr     => "$!",
					 connection => $self);
    }

    $self->connecting($! == EINPROGRESS);

    if (!$self->connecting()) {
      $call_complete = 1;
    }
  }

  $self->Danger::Server::Readable::configure($socket, $consume_fn, $eof_fn);
  $self->Danger::Server::Writable::configure($socket);

  $self->{server} = $server;
  $server->add_connection($self);

  $self->complete_fn($complete_fn);
  $self->fail_fn($fail_fn);

  if ($call_complete) {
    $self->complete();
  }
}

sub complete_fn { shift->_field(complete_fn => @_) }
sub connecting  { shift->_field(connecting  => @_) }
sub fail_fn     { shift->_field(fail_fn     => @_) }
sub server      { shift->_field(server      => @_) }

sub socket      { shift->read_fh() }

sub complete {
  my $self = shift;

  $self->connecting(0);

  if (defined(my $complete_fn = $self->complete_fn())) {
    &$complete_fn($self);
  }
}

sub fail {
  my($self, $errno) = @_;

  if (defined(my $fail_fn = $self->fail_fn())) {
    &$fail_fn($self, $errno);
  }

  $self->close();
}

sub close {
  my($self, $immediate) = @_;

  $self->Danger::Server::Writable::close($immediate);

  if ($immediate) {
    $self->Danger::Server::Readable::close();

    my $server = $self->server();
    $server->remove_connection($self);
  }
}

1;
