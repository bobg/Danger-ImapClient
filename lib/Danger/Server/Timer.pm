# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Timer;

use base qw(Danger::Server::Thing);

sub configure {
  my($self, $server, $when, $what) = @_;

  $self->SUPER::configure(server => $server,
                          when   => $when,
                          what   => $what);

  $server->add_timer($self);
}

sub server { shift->_field(server => @_) }
sub what   { shift->_field(what => @_) }
sub when   { shift->_field(when => @_) }

sub maybe_trigger {
  my $self = shift;

  if ($self->when() <= time) {
    $self->trigger();
  }
}

sub trigger {
  my $self = shift;
  my $server = $self->server();
  my $fn = $self->what();
  &$fn();
  $server->remove_timer($self);
}

sub cancel {
  my $self = shift;
  my $server = $self->server();
  $server->remove_timer($self);
}

1;
