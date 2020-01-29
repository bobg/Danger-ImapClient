# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Thing;

sub new {
  my $type = shift;

  my $self = {};
  bless $self, $type;

  $self->configure(@_);

  return $self;
}

sub configure {
  my $self = shift;
  my %fields = @_;

  while (my($key, $val) = each %fields) {
    $self->{$key} = $val;
  }
}

sub _field {
  my $self = shift;
  my $field = shift;

  if (@_) {
    $self->{$field} = shift;
  }
  return $self->{$field};
}

1;
