use strict;
use warnings;

############################################################

package Danger::Server::IMAPClient::SyntaxError;

use base qw(Danger::Error);

sub new {
  my($type, $imap, $ptr, $expected) = @_;
  my $offset = pos($$ptr);

  my $self = new Danger::Error(imap     => $imap,
                               ptr      => $ptr,
                               offset   => $offset,
                               expected => $expected);

  bless $self, $type;
}

############################################################

package Danger::Server::IMAPClient;

use base qw(Danger::Server::Connection);

use Danger::Error;
use Danger::Logger qw(logf);
use Time::HiRes ();

@Danger::Server::IMAPClient::UnknownTagError::ISA = qw(Danger::Error);

my %months = (jan => 1, feb => 2, mar => 3,
              apr => 4, may => 5, jun => 6,
              jul => 7, aug => 8, sep => 9,
              oct => 10, nov => 11, dec => 12);

sub configure {
  my($self, $server, %args) = @_;

  $args{consume_fn} = \&imap_consume;
  $args{port} ||= 143;
  $self->SUPER::configure($server, %args);
}

############################################################

sub imap_consume {
  my($self, $bufptr, $eof) = @_;

  pos($$bufptr) = 0;

  while (1) {
    # This block looks for the first CRLF that's not part of a "literal."
    # That CRLF will be the end of the first response in $$bufptr.
    # Note that there are pathological cases where a line can end in
    # {ddd} without being part of a literal.  Thank you again, Mr. Crispin.
    pos($$bufptr) = 0;
    while ($$bufptr =~ /\G.*?\{(\d+)\}\r?\n/gc) {
      my $newpos = pos($$bufptr) + $1;
      return if ($newpos >= length($$bufptr)); # incomplete
      pos($$bufptr) = $newpos;
    }
    if ($$bufptr !~ /\G.*?\r?\n/g) {
      # incomplete response
      return;
    }

    my $response = substr($$bufptr, 0, pos($$bufptr));
    $$bufptr = substr($$bufptr, pos($$bufptr));

    &logf(LOG_DEBUG2 => 0, "IMAP response: %D", $response);

    if ($response =~ /\A\+\s+/g) {
      # continue-req
    } elsif ($response =~ /\A\*\s+/g) {
      # response-data or response-fatal
      if (defined(my $resp_cond_state = $self->try_parse_resp_cond_state(\$response))) {
        $self->handle_resp_cond_state($resp_cond_state);
      } elsif ($response =~ /\Gbye\s+/gci) {
        my $resp_text = $self->parse_resp_text(\$response);
        $self->handle_resp_cond_bye($resp_text);
      } elsif ($response =~ /\Gflags\s+/gci) {
        if ($response !~ /\G\((.*?)\)/gc) {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'flag-list');
        }
        my $flags = $1;
        my @flags = ($flags =~ /(\S+)/g);
        $self->handle_mailbox_flags(\@flags);
      } elsif ($response =~ /\G(list|lsub)\s+/gci) {
        my $type = lc($1);

        if ($response !~ /\G\((.*?)\)\s+/gc) {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'mbx-list-flags');
        }
        my $flags = $1;
        my @flags = ($flags =~ /(\S+)/gc);

        my $hdelim;
        if ($response =~ /\Gnil/gci) {
          # do nothing
        } elsif ($response =~ /\G\"((?:[^\\\"]*|\\.)*)\"/gci) {
          $hdelim = $1;
          $hdelim =~ s/\\(.)/$1/g;
        } else {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'hierarchy-delimiter');
        }

        &skipws(\$response);

        my $mailbox = $self->parse_mailbox(\$response);

        $self->handle_mailbox_list($type, $mailbox, $hdelim, \@flags);
      } elsif ($response =~ /\Gsearch\s*/gci) {
        my @msgnums = ($response =~ /\G(\d+)/gc);
        $self->handle_search(\@msgnums);
      } elsif ($response =~ /\Gstatus\s+/gci) {
        my $mailbox = $self->parse_mailbox(\$response);
        if ($response !~ /\G\((.*?)\)/gc) {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'status-att-list');
        }

        my $status_att_list = lc($1);
        my @status_att_list = ($status_att_list =~ /(\S+)/g);

        $self->handle_status($mailbox, \@status_att_list);
      } elsif ($response =~ /\G(\d+)\s+(exists|recent)/gci) {
        $self->handle_mailbox_count($1, lc($2));
      } elsif ($response =~ /\G(\d+)\s+expunge/gci) {
        $self->handle_expunge($1);
      } elsif ($response =~ /\G(\d+)\s+fetch\s+/gci) {
        my $msgnum = $1;

        if ($response !~ /\G\(/gc) {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'msg-att-list');
        }
        while ($response !~ /\G\)/gc) {
          &skipws(\$response);

          if ($response =~ /\Gflags\s+/gci) {
            if ($response !~ /\G\((.*?)\)/gc) {
              throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'flag-fetch');
            }
            my $flags = $1;
            my @flags = ($flags =~ /(\S+)/g);

            $self->handle_message_flags($msgnum, \@flags);
          } elsif ($response =~ /\Genvelope\s+/gci) {
            my $envelope = $self->parse_envelope(\$response);

            $self->handle_envelope($msgnum, $envelope);
          } elsif ($response =~ /\Ginternaldate\s+\"\s*(\d+)-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-(\d+)\s+(\d+):(\d+):(\d+)\s+([+-]\d+)\"/gci) {
            my($d, $mon, $y, $h, $min, $s, $z) = ($1, $2, $3, $4, $5, $6, $7);

            $mon = $months{lc($mon)};

            $self->handle_internaldate($msgnum, [$y, $mon, $d, $h, $min, $s, $z]);
          } elsif ($response =~ /\Grfc822(?:\.(header|text))?\s+/gci) {
            my $type = ($1 || '');
            $type = lc($type);

            my $content = $self->parse_nstring(\$response);

            if ($type eq 'header') {
              $self->handle_message($msgnum, undef, 'header', undef, $content);
            } elsif ($type eq 'text') {
              $self->handle_message($msgnum, undef, 'text', undef, $content);
            } else {
              $self->handle_message($msgnum, undef, undef, undef, $content);
            }
          } elsif ($response =~ /\Grfc822\.size\s+(\d+)/gci) {
            $self->handle_size($msgnum, $1);
          } elsif ($response =~ /\Gbody(?:structure)?\s+/gci) {
            my $body = $self->parse_body(\$response);
            $self->handle_bodystructure($msgnum, $body);
          } elsif ($response =~ /\Gbody\[/gci) {
            my $partnum;
            my $section_text = $self->try_parse_section_msgtext(\$response);
            if (!defined($section_text)) {
              if ($response =~ /\G((?:\d+)(?:\.\d+)*)/gc) {
                $partnum = $1;
                if ($response =~ /\G\./gc) {
                  $section_text = $self->parse_section_text(\$response);
                }
              }
            }
            if ($response !~ /\G\]/gc) {
              throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'section');
            }
            my $offset;
            if ($response =~ /\G<(\d+)>/gc) {
              $offset = $1;
            }
            my $content = $self->parse_nstring(\$response);

            $self->handle_message($msgnum, $partnum, $section_text, $offset, $content);
          } elsif ($response =~ /\Guid\s+(\d+)/gci) {
            $self->handle_uid($msgnum, $1);
          } else {
            throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'msg-att');
          }
        }
      } elsif (my $capability_data =
               $self->try_parse_capability_data(\$response)) {
        $self->handle_capability($capability_data);
      } elsif ($response =~ /\Gquotaroot\s+/gci) {
        my $mailbox = $self->parse_astring(\$response);
        my @quotaroots;
        while (1) {
          &skipws(\$response);
          my $result = $self->try_parse_astring(\$response);
          last unless defined($result);
          push(@quotaroots, $result);
        }
        $self->handle_quotaroot($mailbox, \@quotaroots);
      } elsif ($response =~ /\Gquota\s+/gci) {
        my $quotaroot = $self->parse_astring(\$response);
        &skipws(\$response);
        if ($response !~ /\G\(/gc) {
          throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'quota-list');
        }
        my %quota;
        while ($response !~ /\G\)/gc) {
          my $name = lc($self->parse_atom(\$response));
          if ($response !~ /\G\s+(\d+)\s+(\d+)\s*/gc) {
            throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'quota-resource');
          }
          my($usage, $limit) = ($1, $2);

          $quota{$name} = [1024 * $usage, 1024 * $limit];
        }
        $self->handle_quota($quotaroot, \%quota);
      } else {
        throw Danger::Server::IMAPClient::SyntaxError($self, \$response, 'response-data');
      }
    } elsif ($response =~ /\A(\S+)\s+/g) {
      # response-tagged
      my $tag = $1;
      my $resp_cond_state = $self->parse_resp_cond_state(\$response);
      $self->handle_tagged_response($tag, $resp_cond_state);
    }
  }
}

############################################################

# Parsing helpers

sub parse_address_list {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\Gnil/gci) {
    return [];
  }
  if ($$ptr !~ /\G\(/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'address-list');
  }
  my @addresses;
  while ($$ptr !~ /\G\)/gc) {
    # address
    &skipws($ptr);
    if ($$ptr !~ /\G\(/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'address');
    }
    my $name = $self->parse_nstring($ptr);
    &skipws($ptr);
    my $adl  = $self->parse_nstring($ptr);
    &skipws($ptr);
    my $mailbox = $self->parse_nstring($ptr);
    &skipws($ptr);
    my $host = $self->parse_nstring($ptr);
    if ($$ptr !~ /\G\)/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'address-end');
    }
    push(@addresses, [$name, $adl, $mailbox, $host]);
  }
  return \@addresses;
}

sub parse_astring {
  my($self, $ptr) = @_;

  if (defined(my $result = $self->try_parse_string($ptr))) {
    return $result;
  }
  if ($$ptr !~ /\G([^()\{ %*\\\"\x00-\x1f\x7f]+)/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'astring');
  }
  return $1;
}

sub parse_atom {
  my($self, $ptr) = @_;

  my $result = $self->try_parse_atom($ptr);
  return $result if defined($result);

  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'atom');
}

sub parse_body {
  my($self, $ptr) = @_;

  my $result = $self->try_parse_body($ptr);
  return $result if defined($result);

  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body');
}

sub parse_body_ext_aux {
  my($self, $ptr) = @_;
  my($body_fld_dsp, $body_fld_lang, $body_fld_loc, $body_extensions);

  my $parsed;
  $body_fld_dsp = $self->try_parse_body_fld_dsp($ptr, \$parsed);
  if ($parsed) {
    &skipws($ptr);
    $body_fld_lang = $self->try_parse_body_fld_lang($ptr, \$parsed);
    if ($parsed) {
      &skipws($ptr);
      $body_fld_loc = $self->try_parse_nstring($ptr, \$parsed);
      if ($parsed) {
        &skipws($ptr);
        $body_extensions = $self->try_parse_body_extensions($ptr);
      }
    }
  }
  return ($body_fld_dsp, $body_fld_lang, $body_fld_loc, $body_extensions);
}

sub parse_body_fields {
  my($self, $ptr) = @_;

  my $param = $self->parse_body_fld_param($ptr);
  &skipws($ptr);
  my $id = $self->parse_nstring($ptr);
  &skipws($ptr);
  my $desc = $self->parse_nstring($ptr);
  &skipws($ptr);
  my $enc = $self->parse_string($ptr);
  &skipws($ptr);
  if ($$ptr !~ /\G(\d+)/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-fld-octets');
  }
  my $octets = $1;

  return [$param, $id, $desc, $enc, $octets];
}

sub parse_body_fld_lines {
  my($self, $ptr) = @_;

  if ($$ptr !~ /\G(\d+)/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-fld-lines');
  }
  return $1;
}

sub parse_body_fld_param {
  my($self, $ptr) = @_;
  my $parsed;
  my $result = $self->try_parse_body_fld_param($ptr, \$parsed);
  return $result if $parsed;
  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-fld-param');
}

sub parse_envelope {
  my($self, $ptr) = @_;

  if ($$ptr !~ /\G\(/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'envelope');
  }
  my $env_date        = $self->parse_nstring($ptr);
  &skipws($ptr);
  my $env_subject     = $self->parse_nstring($ptr);
  &skipws($ptr);
  my $env_from        = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_sender      = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_reply_to    = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_to          = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_cc          = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_bcc         = $self->parse_address_list($ptr);
  &skipws($ptr);
  my $env_in_reply_to = $self->parse_nstring($ptr);
  &skipws($ptr);
  my $env_message_id  = $self->parse_nstring($ptr);

  if ($$ptr !~ /\G\)/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'envelope-end');
  }

  return [$env_date, $env_subject, $env_from,
          $env_sender, $env_reply_to, $env_to,
          $env_cc, $env_bcc, $env_in_reply_to, $env_message_id];
}

sub parse_mailbox {
  my($self, $ptr) = @_;

  my $result = $self->parse_astring($ptr);
  if (lc($result) eq 'inbox') {
    return 'INBOX';
  }
  return $result;
}

sub parse_nstring {
  my($self, $ptr) = @_;

  my $parsed;
  my $result = $self->try_parse_nstring($ptr, \$parsed);
  return $result if $parsed;

  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'nstring');
}

sub parse_resp_cond_state {
  my($self, $ptr) = @_;

  my $result = $self->try_parse_resp_cond_state($ptr);
  return $result if defined($result);

  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'resp-cond-state');
}

sub parse_resp_text {
  my($self, $ptr) = @_;

  my $resp_text_code;
  if ($$ptr =~ /\G\[/gc) {
    # resp-text-code
    if ($$ptr =~ /\G(alert|parse|read-only|read-write|trycreate)/gci) {
      $resp_text_code = [lc($1)];
    } elsif ($$ptr =~ /\Gbadcharset\s*/gci) {
      $resp_text_code = ['badcharset'];
      if ($$ptr =~ /\G\(/gc) {
        my @charsets;
        while ($$ptr !~ /\G\)/gc) {
          my $astring = $self->parse_astring($ptr);
          push(@charsets, $astring);
          &skipws($ptr);
        }
        $resp_text_code->[1] = \@charsets;
      }
    } elsif (my $capability_data = $self->try_parse_capability_data($ptr)) {
      $resp_text_code = [capability => $capability_data];
    } elsif ($$ptr =~ /\Gpermanentflags\s*\((.*?)\)/gci) {
      my $flags = $1;
      my @flags = ($flags =~ /(\S+)/g);
      $resp_text_code = [permanentflags => \@flags];
    } elsif ($$ptr =~ /\G(uidnext|uidvalidity|unseen)\s+(\d+)/gci) {
      $resp_text_code = [$1, $2];
    } elsif (my $atom = $self->try_parse_atom($ptr)) {
      &skipws($ptr);
      my($rest) = ($$ptr =~ /\G([^\]\r\n]*)/gc);
      $resp_text_code = [$atom, $rest];
    } else {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'resp-text-code');
    }
    if ($$ptr !~ /\G\]\s*/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'resp-text-code-end');
    }
  }
  my($text) = ($$ptr =~ /\G([^\r\n]*)/gc);

  return [$resp_text_code, $text];
}

sub parse_section_text {
  my($self, $ptr) = @_;

  my $result = $self->try_parse_section_msgtext($ptr);
  return $result if defined($result);

  if ($$ptr !~ /\Gmime/gci) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'section-text');
  }

  return 'mime';
}

sub parse_string {
  my($self, $ptr) = @_;

  my $result = $self->try_parse_string($ptr);
  return $result if defined($result);

  throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'string');
}

sub try_parse_atom {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\G([^\]()\{ %*\\\"\x00-\x1f\x7f]+)/gc) {
    return $1;
  }
  return undef;
}

sub try_parse_body {
  my($self, $ptr) = @_;

  &skipws($ptr);

  if ($$ptr !~ /\G\(/gc) {
    return undef;
  }

  my @subparts;
  while (defined(my $subpart = $self->try_parse_body($ptr))) {
    push(@subparts, $subpart);
  }

  &skipws($ptr);

  my %result;

  my $major;
  if (@subparts) {
    $major = 'multipart';
    $result{subparts} = \@subparts;
  } else {
    $major = lc($self->parse_string($ptr));
  }

  &skipws($ptr);

  my $minor = lc($self->parse_string($ptr));

  $result{major} = $major;
  $result{minor} = $minor;

  &skipws($ptr);

  if (@subparts) {
    # body-ext-mpart

    my $parsed;
    my $body_fld_param = $self->try_parse_body_fld_param($ptr, \$parsed);
    $result{body_fld_param} = $body_fld_param;

    if ($parsed) {
      &skipws($ptr);
      my($body_fld_dsp, $body_fld_lang, $body_fld_loc, $body_extensions) =
          $self->parse_body_ext_aux($ptr);
      $result{body_fld_dsp}    = $body_fld_dsp;
      $result{body_fld_lang}   = $body_fld_lang;
      $result{body_fld_loc}    = $body_fld_loc;
      $result{body_extensions} = $body_extensions;
    }
  } else {
    my $body_fields = $self->parse_body_fields($ptr);
    $result{body_fields} = $body_fields;

    &skipws($ptr);
    if ($major eq 'text') {
      my $lines = $self->parse_body_fld_lines($ptr);
      $result{body_fld_lines} = $lines;
    } elsif (($major eq 'message') && ($minor eq 'rfc822')) {
      my $envelope = $self->parse_envelope($ptr);
      &skipws($ptr);
      my $subpart  = $self->parse_body($ptr);
      &skipws($ptr);
      my $lines    = $self->parse_body_fld_lines($ptr);
      $result{envelope}       = $envelope;
      $result{subpart}        = $subpart;
      $result{body_fld_lines} = $lines;
    }
    # body-ext-1part
    &skipws($ptr);

    my $parsed;
    my $body_fld_md5 = $self->try_parse_nstring($ptr, \$parsed);
    $result{body_fld_md5} = $body_fld_md5;

    if ($parsed) {
      &skipws($ptr);
      my($body_fld_dsp, $body_fld_lang, $body_fld_loc, $body_extensions) =
          $self->parse_body_ext_aux($ptr);
      $result{body_fld_dsp}    = $body_fld_dsp;
      $result{body_fld_lang}   = $body_fld_lang;
      $result{body_fld_loc}    = $body_fld_loc;
      $result{body_extensions} = $body_extensions;
    }
  }

  if ($$ptr !~ /\G\)/gc) {
    throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-end');
  }

  return \%result;
}

sub try_parse_body_extension {
  my($self, $ptr, $parsedptr) = @_;

  my $result = $self->try_parse_nstring($ptr, $parsedptr);
  return $result if $$parsedptr;

  if ($$ptr =~ /\G(\d+)/gc) {
    $$parsedptr = 1;
    return $1;
  }

  if ($$ptr =~ /\G\(/gc) {
    $result = $self->try_parse_body_extensions($ptr);
    if ($$ptr !~ /\G\)/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-extensions-end');
    }
    $$parsedptr = 1;
    return $result;
  }
  $$parsedptr = 0;
  return undef;
}

sub try_parse_body_extensions {
  my($self, $ptr) = @_;

  my $parsed;
  my @result;
  while (1) {
    my $extension = $self->try_parse_body_extension($ptr, \$parsed);
    last unless $parsed;
    push(@result, $extension);
    &skipws($ptr);
  }
  return \@result if @result;
  return undef;
}

sub try_parse_body_fld_dsp {
  my($self, $ptr, $parsedptr) = @_;

  if ($$ptr =~ /\Gnil/gci) {
    $$parsedptr = 1;
    return undef;
  }
  if ($$ptr =~ /\G\(/gc) {
    my $str = $self->parse_string($ptr);
    &skipws($ptr);
    my $param = $self->parse_body_fld_param($ptr);
    $$parsedptr = 1;
    return [$str, $param];
  }
  $$parsedptr = 0;
  return undef;
}

sub try_parse_body_fld_lang {
  my($self, $ptr, $parsedptr) = @_;

  my $result = $self->try_parse_nstring($ptr, $parsedptr);
  return $result if $$parsedptr;

  if ($$ptr =~ /\G\(/gc) {
    my @result;
    while (defined(my $str = $self->try_parse_string($ptr))) {
      push(@result, $str);
      &skipws($ptr);
    }
    if ($$ptr !~ /\G\)/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'body-fld-lang-end');
    }
    $$parsedptr = 1;
    return \@result;
  }
  $$parsedptr = 0;
  return undef;
}

sub try_parse_body_fld_param {
  my($self, $ptr, $parsedptr) = @_;

  if ($$ptr =~ /\Gnil/gci) {
    $$parsedptr = 1;
    return undef;
  }
  if ($$ptr =~ /\G\(/gc) {
    my @result;
    while (1) {
      my $str1 = $self->parse_string($ptr);
      &skipws($ptr);
      my $str2 = $self->parse_string($ptr);
      push(@result, $str1, $str2);
      last if ($$ptr =~ /\G\)/gc);
      &skipws($ptr);
    }
    $$parsedptr = 1;
    return \@result;
  }
  $$parsedptr = 0;
  return undef;
}

sub try_parse_capability_data {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\Gcapability\s+/gci) {
    my @capabilities;
    while (1) {
      &skipws($ptr);
      my $auth;
      if ($$ptr =~ /\Gauth=/gci) {
        $auth = 'AUTH=';
      } else {
        $auth = '';
      }
      my $atom;
      if (defined($atom = $self->try_parse_atom($ptr))) {
        push(@capabilities, "$auth$atom");
      } elsif ($auth) {
        throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'auth-capability');
      } else {
        last;
      }
    }
    return \@capabilities;
  }
  return undef;
}

sub try_parse_nstring {
  my($self, $ptr, $parsedptr) = @_;

  if (defined(my $result = $self->try_parse_string($ptr))) {
    $$parsedptr = 1;
    return $result;
  }
  if ($$ptr =~ /\Gnil/gci) {
    $$parsedptr = 1;
    return undef;
  }
  $$parsedptr = 0;
  return undef;
}

# also handles resp-cond-auth
sub try_parse_resp_cond_state {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\G(ok|no|bad|preauth)\s+/gci) {
    my $code = lc($1);
    my $resp_text = $self->parse_resp_text($ptr);
    return [$code, $resp_text];
  }
  return undef;
}

sub try_parse_section_msgtext {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\Gheader\.fields(\.not)?\s+/gci) {
    my $not = (defined($1) && $1);
    my @fields;

    if ($$ptr !~ /\G\(/gc) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'header-list');
    }
    while ($$ptr !~ /\G\s*\)/gc) {
      &skipws($ptr);
      my $astring = $self->parse_astring($ptr);
      push(@fields, $astring);
    }

    return [($not ? 'not' : 'fields'), @fields];
  }
  if ($$ptr =~ /\G(header|text)/gci) {
    return lc($1);
  }
  return undef;
}

sub try_parse_string {
  my($self, $ptr) = @_;

  if ($$ptr =~ /\G\"((?:[^\\\"]*|\\.)*)\"/gc) {
    my $result = $1;
    $result =~ s/\\(.)/$1/g;
    return $result;
  }
  if ($$ptr =~ /\G\{(\d+)\}\r?\n/gc) {
    my $count = $1;
    my $end = pos($$ptr) + $count;
    if ($end > (length($$ptr) + 1)) {
      throw Danger::Server::IMAPClient::SyntaxError($self, $ptr, 'literal');
    }
    my $result = substr($$ptr, pos($$ptr), $count);
    pos($$ptr) = $end;
    return $result;
  }
  return undef;
}

sub skipws {
  my $ptr = shift;

  $$ptr =~ /\G\s*/gc;
}

############################################################

# Store IMAP data

sub reset_mailbox_data {
  my $self = shift;

  $self->{mailbox} = {};
  $self->{messages} = [];
}

sub set_message_data {
  my($self, $msgnum, $key, $value) = @_;

  $self->{messages} ||= [];
  $self->{messages}->[$msgnum] ||= {};
  $self->{messages}->[$msgnum]->{$key} = $value;
}

sub set_mailbox_data {
  my($self, $key, $value) = @_;

  $self->{mailbox} ||= {};
  $self->{mailbox}->{$key} = $value;
}

sub handle_bodystructure {
  my($self, $msgnum, $body) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_bodystructure(%d):\n%D", $msgnum, $body);

  $self->set_message_data($msgnum, bodystructure => $body);
}

sub handle_capability {
  my($self, $capabilities) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_capabilities:\n%D", $capabilities);

  $self->{capabilities} = $capabilities;
}

sub handle_envelope {
  my($self, $msgnum, $envelope) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_envelope(%d):\n%D", $msgnum, $envelope);

  $self->set_message_data($msgnum, envelope => $envelope);
}

sub handle_expunge {
  my($self, $msgnum) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_expunge(%d)", $msgnum);

  if (defined(my $msglist = $self->{messages})) {
    if (defined(my $msg = $msglist->[$msgnum])) {
      if (defined(my $uid = $msg->{uid})) {
        delete $self->{uidmap}->{$uid};
      }
    }
    if ($#$msglist >= $msgnum) {
      splice(@$msglist, $msgnum, 1);
    }
  }

  if (defined(my $mailbox_data = $self->{mailbox})) {
    if (defined(my $exists = $mailbox_data->{exists})) {
      $mailbox_data->{exists} = --$exists;
    }
  }
}

sub handle_internaldate {
  my($self, $msgnum, $date) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_internaldate(%d):\n%D", $msgnum, $date);

  $self->set_message_data($msgnum, internaldate => $date);
}

sub handle_mailbox_count {
  my($self, $count, $type) = @_; # type is 'exists' or 'recent'

  &logf(LOG_DEBUG2 => 0, "handle_mailbox_count(%d, %s)", $count, $type);

  $self->set_mailbox_data($type, $count);
}

sub handle_mailbox_flags {
  my($self, $flags) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_mailbox_flags:\n%D", $flags);

  $self->set_mailbox_data(flags => $flags);
}

sub handle_mailbox_list {
  my($self, $type, $mailbox, $hdelim, $flags) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_mailbox_list(%s, %s, %s), flags:\n%D",
        $type, $mailbox, $hdelim, $flags);

  $self->{mailboxes} ||= {};
  $self->{mailboxes}->{$mailbox} ||= {};

  my $entry = $self->{mailboxes}->{$mailbox};
  $entry->{lsub} ||= ($type eq 'lsub');
  $entry->{hdelim} = $hdelim;
  $entry->{flags}  = $flags;
}

sub handle_message {
  my($self, $msgnum, $partnum, $section, $offset, $content) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_message(%d, %s), offset %d, section:\n%D",
        $msgnum, $partnum, $offset);

  $self->{messages} ||= [];
  my $msglist = $self->{messages};

  $msglist->[$msgnum] ||= {};
  my $msg = $msglist->[$msgnum];

  $msg->{parts} ||= {};
  my $parts = $msg->{parts};

  $partnum = 0 unless defined($partnum);

  $parts->{$partnum} ||= {};
  my $sections = $parts->{$partnum};

  $section = 'rfc822' unless defined($section);

  if (ref($section)) {
    # it's HEADER.FIELDS or HEADER.FIELDS.NOT
    # xxx ack, what about partials? e.g. BODY[HEADER.FIELDS (FROM TO)]<5.10>
    $sections->{fields} ||= {};
    my $fields = $section->{fields};
    my @fields = split(/\r?\n(?!\s)/, $content);
    foreach my $field (@fields) {
      my($name, $val) = split(/:/, $field, 2);
      $name = lc($name);
      $fields->{$name} ||= [];
      push(@{$fields->{name}}, $val);
    }
  } elsif (defined($offset)) {
    $sections->{$section} = '' unless defined($sections->{$section});

    if ($offset > length($sections->{$section})) {
      # can't use substr() as lvalue wholly outside string bounds
      $sections->{$section} .= ("\x00" x ($offset - length($sections->{$section})));
    }

    substr($sections->{$section}, $offset, length($content)) = $content;
  } else {
    $sections->{$section} = $content;
  }
}

sub handle_message_flags {
  my($self, $msgnum, $flags) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_message_flags(%d):\n%D", $msgnum, $flags);

  $self->set_message_data($msgnum, $flags);
}

sub handle_quotaroot {
  my($self, $mailbox, $quotaroots) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_quotaroot(%s):\n%D", $mailbox, $quotaroots);

  $self->set_mailbox_data($mailbox, $quotaroots);
  $self->{quota} ||= {};
  foreach my $quotaroot (@$quotaroots) {
    $self->{quota}->{$quotaroot} ||= {};
  }
}

sub handle_quota {
  my($self, $quotaroot, $quota) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_quota(%s):\n%D", $quotaroot, $quota);

  $self->{quota} ||= {};
  $self->{quota}->{$quotaroot} ||= {};

  my $hash = $self->{quota}->{$quotaroot};

  foreach my $key (keys %$quota) {
    $hash->{$key} = $quota->{$key};
  }
}

sub handle_resp_cond_bye {
  my($self, $resp_text) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_resp_cond_bye:\n%D", $resp_text);
  # xxx do something?
}

sub handle_resp_cond_state {
  my($self, $resp_cond_state) = @_;
  my($code, $resp_text) = @$resp_cond_state;
  my($resp_text_code, $text) = @$resp_text;

  my $resp_text_code_key = $resp_text_code->[0] if defined($resp_text_code);

  &logf(LOG_DEBUG2 => 0, "handle_resp_cond_state:\n%D", $resp_cond_state);

  if (($code eq 'ok') && defined($resp_text_code)) {
    if ($resp_text_code_key eq 'read-only') {
      $self->set_mailbox_data(writable => 0);
    } elsif ($resp_text_code_key eq 'read-write') {
      $self->set_mailbox_data(writable => 1);
    } elsif ($resp_text_code_key eq 'capability') {
      $self->{capabilities} = $resp_text_code->[1];
    } elsif ($resp_text_code_key eq 'permanentflags') {
      $self->set_mailbox_data(permanentflags => $resp_text_code->[1]);
    } elsif ($resp_text_code_key eq 'uidnext') {
      $self->set_mailbox_data(uidnext => $resp_text_code->[1]);
    } elsif ($resp_text_code_key eq 'uidvalidity') {
      $self->set_mailbox_data(uidvalidity => $resp_text_code->[1]);
    } elsif ($resp_text_code_key eq 'unseen') {
      $self->set_mailbox_data(unseen => $resp_text_code->[1]);
    }                           # else ignore unknown resp-text-codes
  }
}

sub handle_search {
  my($self, $msgnums) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_search:\n%D", $msgnums);

  $self->set_mailbox_data(search => $msgnums);
}

sub handle_size {
  my($self, $msgnum, $size) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_size(%d) => %d", $msgnum, $size);

  $self->set_message_data($msgnum, size => $size);
}

sub handle_status {
  my($self, $mailbox, $status_att_list) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_status(%s):\n%D", $mailbox, $status_att_list);

  for (my $i = 0; $i < @$status_att_list; $i += 2) {
    my $att = $status_att_list->[$i];
    my $num = $status_att_list->[$i+1];

    $att = 'exists' if ($att eq 'messages');

    if (grep { $att eq $_ } qw(exists recent uidnext uidvalidity unseen)) {
      $self->set_mailbox_data($att, $num);
    }
  }
}

sub handle_tagged_response {
  my($self, $tag, $resp_cond_state) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_tagged_response(%s):\n%D", $tag, $resp_cond_state);

  $self->handle_resp_cond_state($resp_cond_state);

  my($code, $resp_text) = @$resp_cond_state;

  my $pending = delete $self->{pending}->{$tag};
  if (!defined($pending)) {
    throw Danger::Server::IMAPClient::UnknownTagError(imap => $self,
                                                      tag => $tag,
                                                      resp_cond_state =>
                                                            $resp_cond_state);
  }
  my($verb, $args, $continue_fn, $error_fn, $start_time) = @$pending;
  my $end_time = &Time::HiRes::time();
  my $elapsed_time = $end_time - $start_time;

  # &logf(LOG_DEBUG => 0,
  #       "Elapsed time for IMAP %s: %.1fs", $verb, $elapsed_time);

  if ((($verb eq 'SELECT') || ($verb eq 'EXAMINE'))
      && ($code ne 'ok')) {
    delete $self->{selected};
  }

  if (($code ne 'ok') && defined($error_fn)) {
    &$error_fn($self, $code, $resp_text, $verb, $args);
  } elsif (defined($continue_fn)) {
    &$continue_fn($self, $code, $resp_text, $verb, $args);
  }
}

sub handle_uid {
  my($self, $msgnum, $uid) = @_;

  &logf(LOG_DEBUG2 => 0, "handle_uid(%d) => %d", $msgnum, $uid);

  $self->{mailbox} ||= {};
  $self->{mailbox}->{uidmap} ||= {};
  $self->{mailbox}->{uidmap}->{$uid} = $msgnum;

  $self->set_message_data($msgnum, uid => $uid);
}

############################################################

# Initiate IMAP actions

sub mkstring {
  my $str = shift;

  $str =~ s/([\\\"])/\\$1/g;
  return "\"$str\"";
}

sub command {
  my $self = shift;

  my $verb = shift;
  $verb = uc($verb);

  my $uid;
  if ($verb eq 'UID') {
    $uid = 1;
    $verb = uc(shift);
  }

  my($continue_fn, $error_fn);

  while (1) {
    if ($_[0] eq 'continue_fn') {
      $continue_fn = $_[1];
      splice(@_, 0, 2);
    } elsif ($_[0] eq 'error_fn') {
      $error_fn = $_[1];
      splice(@_, 0, 2);
    } else {
      last;
    }
  }

  my $args;
  my @post_fns;

  if ($verb eq 'LOGIN') {
    my $username = shift;
    my $password = shift;

    $args = join(' ', &mkstring($username), &mkstring($password));
  } elsif (($verb eq 'SELECT') || ($verb eq 'EXAMINE')) {
    my $mailbox = shift;
    $args = &mkstring($mailbox);
    push(@post_fns, sub {
      $self->reset_mailbox_data();
      $self->{selected} = $mailbox;
    });
  } elsif ($verb eq 'GETQUOTA') {
    my $quotaroot = shift;
    $args = &mkstring($quotaroot);
  } elsif (($verb eq 'LIST') || ($verb eq 'LSUB')) {
    my $refname = shift;
    my $mboxname = shift;
    $args = sprintf('%s %s',
                    &mkstring($refname), &mkstring($mboxname));
  } elsif ($verb eq 'FETCH') {
    my $msgspec = shift;
    my $items = shift;

    if (ref($msgspec)) {
      $msgspec = join(',', @$msgspec); # xxx use Set::IntSpan
    }

    $args = "$msgspec ";

    if (ref($items)) {
      if (@$items > 1) {
        $args .= sprintf('(%s)', join(' ', @$items));
      } else {
        $args .= $items->[0];
      }
    } else {
      $args .= $items;
    }
  } elsif ($verb eq 'STORE') {
    my $msgspec = shift;
    my $item = shift;
    my $value = shift;

    if (ref($msgspec)) {
      $msgspec = join(',', @$msgspec); # xxx use Set::IntSpan
    }

    $args = "$msgspec $item (";

    if (ref($value)) {
      $args .= join(' ', @$value);
    } else {
      $args .= $value;
    }

    $args .= ")";
  }

  $self->{tag} ||= 'A000';      # what the heck
  my $tag = ++$self->{tag};

  my $cmd = "$tag ";
  $cmd .= "UID " if $uid;
  $cmd .= $verb;
  if (defined($args)) {
    $cmd .= " $args";
  }

  &logf(LOG_DEBUG2 => 0, "Sending: %s", $cmd);

  $self->write($cmd, "\r\n",
               sub {
                 $self->{pending} ||= {};
                 $self->{pending}->{$tag} =
                     [$verb, $args, $continue_fn, $error_fn,
                      &Time::HiRes::time()];
               }, @post_fns);
}

sub getquota {
  my $self = shift;
  $self->command(getquota => @_);
}
sub list {
  my $self = shift;
  $self->command(list => @_);
}

sub sequence {
  my($self, @sequence) = @_;

  my $overall_error_fn;
  if ($sequence[0] eq 'error_fn') {
    $overall_error_fn = $sequence[1];
    splice(@sequence, 0, 2);
  }

  my $error_fn;
  my $iterate;
  $iterate = sub {
    return unless @sequence;
    my $first = shift @sequence;
    my %modifiers;
    while (@sequence && !ref($sequence[0])) {
      my $key = shift @sequence;
      my $val = shift @sequence;
      $modifiers{$key} = $val;
    }
    my $continue_fn;
    if (@sequence) {
      if (ref($sequence[0]) eq 'CODE') {
        my $fn = shift @sequence;
        $continue_fn = sub { &$fn(@_); &$iterate(); };
      } elsif (defined($modifiers{continue_fn})) {
        my $fn = $modifiers{continue_fn};
        $continue_fn = sub { &$fn(@_); &$iterate(); };
      } else {
        $continue_fn = $iterate;
      }
    }
    my($verb, @rest) = @$first;
    $verb = uc($verb);
    my @verb = ($verb);
    if ($verb eq 'UID') {
      push(@verb, uc(shift(@rest)));
    }
    $self->command(@verb,
                   continue_fn => $continue_fn,
                   error_fn    => ($modifiers{error_fn} || $overall_error_fn),
                   @rest);
  };
  &$iterate();
}

############################################################

# Accessors for previously obtained IMAP data go here

sub foreach_message {
  my($self, $fn) = @_;

  my $list = $self->{messages};
  return unless $list;

  for (my $i = 1; $i <= $#$list; ++$i) {
    &$fn($self, $i, $list->[$i]);
  }
}

sub foreach_folder {
  my($self, $fn) = @_;

  my $hash = $self->{mailboxes};
  return unless $hash;

  foreach my $name (keys %$hash) {
    &$fn($self, $name, $hash->{$name});
  }
}

sub quota {
  my($self, $quotaroot, $key) = @_;

  my $hash = $self->{quota};
  return () unless $hash;

  $hash = $hash->{$quotaroot};
  return () unless $hash;

  my $pair = $hash->{lc($key)};
  return () unless $pair;

  return @$pair;
}

sub uids {
  my $self = shift;

  my $hash = $self->{mailbox};
  return () unless $hash;

  $hash = $hash->{uidmap};
  return () unless $hash;

  return keys %$hash;
}

1;
