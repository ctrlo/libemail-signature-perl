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

my $emailsig = Email::Signature->new;
$emailsig->addHtmlPart(1);

# Should now have 2 parts, after HTML part is added
my $newplainmsg = $emailsig->sign($plainmsg);
ok( $newplainmsg->parts == 2 );

# Parent part should be multipart/alternative
ok( $newplainmsg->body->mimeType eq 'multipart/alternative');

