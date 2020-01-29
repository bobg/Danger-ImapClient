# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Listener;

use base qw(Danger::Server::Thing);

use Danger::Error;
use Danger::Server::Connection;
use IO::Socket::INET;

@Danger::Server::ListenerError::ISA = qw(Danger::Error);

sub new {
  my($type, $server, $port, $accept_fn, $consume_fn, $eof_fn) = @_;

  my $socket = new IO::Socket::INET(LocalPort => $port,
				    Proto     => 'tcp',
				    Listen    => 5,
				    ReuseAddr => 1);
  if (!defined($socket)) {
    throw Danger::Server::ListenerError(server => $server,
                                        errno  => $!,
                                        errstr => "$!",
                                        port   => $port);
  }

  my $self = new Danger::Server::Thing(accept_fn  => $accept_fn,
                                       consume_fn => $consume_fn,
                                       eof_fn     => $eof_fn,
                                       socket     => $socket,
                                       server     => $server);
  bless $self, $type;

  $server->add_listener($self);

  return $self;
}

sub accept_fn  { shift->_field(accept_fn => @_) }
sub consume_fn { shift->_field(consume_fn => @_) }
sub eof_fn     { shift->_field(eof_fn => @_) }
sub server     { shift->_field(server => @_) }
sub socket     { shift->_field(socket => @_) }

sub accept {
  my $self = shift;

  my $socket = $self->socket();
  my $fh = $socket->accept();   # xxx check
  $fh->blocking(0);
  $fh->autoflush(1);

  if (defined(my $accept_fn = $self->accept_fn())) {
    &$accept_fn($self, $fh);
  } else {
    my $server = $self->server();
    new Danger::Server::Connection($server,
				   socket     => $fh,
                                   consume_fn => $self->consume_fn(),
				   eof_fn     => $self->eof_fn());
  }
  
  return $fh;
}

sub close {
  my $self = shift;
  my $fh = $self->socket();
  $fh->close();

  my $server = $self->server();
  $server->remove_listener($self);
}

1;
