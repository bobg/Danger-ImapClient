use strict;
use warnings;

package Danger::Server::HTTPClient;

use base qw(Danger::Server::Connection);

sub configure {
  my($self, $server, %args) = @_;

  my $response_fn = delete $args{response_fn};
  $self->response_fn($response_fn);

  $self->SUPER::configure($server,
                          consume_fn => \&http_consume_fn,
                          %args);
}

sub response_fn      { shift->_field(response_fn      => @_) }
sub head_pending     { shift->_field(head_pending     => @_) }
sub request_callback { shift->_field(request_callback => @_) }

sub send_request {
  my($self, $request, $callback) = @_;

  my $method = $request->method();
  my $uri = $request->uri();

  my $host = $uri->host();
  my $port = $uri->port();
  my $path = $uri->path();

  $self->write("$method $path HTTP/1.1\r\n");

  my $content = $request->content();
  $content = '' unless defined($content);
  $content =~ s/\r?\n/\r\n/g;

  my $header = new HTTP::Headers();
  $header->header(Content_Length => length($content),
                  Host           => "$host:$port");
  $header = $header->as_string();
  $header =~ s/\r?\n/\r\n/g;

  $self->write($header, "\r\n", $content,
               sub {
                 $self->head_pending(lc($method) eq 'head');
                 $self->request_callback($callback);
               });
}

# xxx to do: make this stateful so we can parse partial responses
# instead of starting from scratch on each iteration (until a complete
# response is present)
sub http_consume_fn {
  my($self, $bufptr, $eof) = @_;

  while ($$bufptr =~ /\r?\n\r?\n/) {
    my $header_end = $-[0];
    my $body_start = $+[0];

    my $header = substr($$bufptr, 0, $header_end);

    my($protocol_version, $status_code, $status_text) =
        ($header =~ /\A(\S+)\s+(\d+)\s+(.*)\r?\n/);

    if (!$status_code) {
      # xxx syntax error
    }

    $header = substr($header, $+[0]);

    my $body_length;

    if (($status_code =~ /^1/)
        || ($status_code =~ /^[23]04$/)
        || $self->head_pending()) {
      # RFC2616 section 4.4 bullet 1
      $body_length = 0;
    } elsif ($header =~ /^transfer-encoding:\s*(?!identity)/im) {
      # RFC2616 section 4.4 bullet 2
      # xxx chunked
    } elsif ($header =~ /^content-length:\s*(\d+)/im) {
      # RFC2616 section 4.4 bullet 3
      $body_length = $1;
    } elsif ($header =~ /^content-type:\s*multipart\/byteranges/im) {
      # RFC2616 section 4.4 bullet 4
      # xxx do byteranges
    } elsif ($eof) {
      # RFC2616 section 4.4 bullet 5
      $body_length = length($$bufptr) - $body_start;
    } else {
      # xxx cannot determine message length
      return;
    }

    my $body_end = $body_start + $body_length;

    if (length($$bufptr) < $body_end) {
      # xxx not enough data yet
      return;
    }

    my $body = substr($$bufptr, $body_start, $body_length);
    $$bufptr = substr($$bufptr, $body_end);

    $self->process_response($protocol_version, $status_code, $status_text,
                            $header, $body);
  }
}

sub process_response {
  my($self, $protocol_version, $status_code, $status_text, $header, $body) = @_;

  my $fn = delete $self->{request_callback};
  $fn ||= $self->response_fn();
  if (defined($fn)) {
    &$fn($self,
         $protocol_version, $status_code, $status_text,
         $header, $body);
  }
}

1;
