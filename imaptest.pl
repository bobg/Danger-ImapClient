#!/danger/local/bin/perl

use strict;
use warnings;

use Danger::Logger qw(set_log_level);
use Danger::Server;
use Danger::Server::IMAPClient;

&set_log_level('LOG_DEBUG2');

my $server = new Danger::Server();

my $imap = new Danger::Server::IMAPClient($server,
                                          complete_fn => \&do_imap_stuff,
                                          host => "a30",
                                          port => 143);

$server->run();

sub do_imap_stuff {
  $imap->sequence([login => 'bobg@pandora.danger.com', 'bobg'],
                  [list => '', '*'],
                  [examine => 'inbox'],
                  [fetch => '1:*', [qw(internaldate)]],
                  ['logout']);
}
