use strict;
use warnings;

use Test::Simple tests => 2;

use Mail::Message;
use Email::Signature;

my $text    = "First line\n";
my $html    = "<html>$text</html>";
my $footerp = "Footer";
my $footerh = "<b>footer</b>";

my $plainmsg = Mail::Message->build
 ( From   => 'me@home.nl'
 , To     => 'you@yourplace.aq'
 , data   => $text
 );

my $htmlmsg = Mail::Message->build
 ( From           => 'me@home.nl'
 , To             => 'you@yourplace.aq'
 , 'Content-Type' => 'text/html'
 , data           => $html
 );

my $footer = {
  plain => $footerp,
  html  => $footerh
};

my $emailsig = Email::Signature->new({ footer => $footer});

my $newplainmsg = $emailsig->sign($plainmsg);
ok( $plainmsg->body->string.$footerp."\n\n" eq $newplainmsg->body->string );

my $newhtmlmsg = $emailsig->sign($htmlmsg);
ok( "<html>$text$footerh</html>" eq $newhtmlmsg->body->string );

