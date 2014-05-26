package Email::Signature;

use warnings;
use strict;

use Carp;
use Mojo::DOM;
use Mail::Message::Body::Lines;

=head1 NAME

Email::Signature - adds a signature and attachments to a Mail::Message object

=head1 VERSION

Version 1.00

=cut

our $VERSION = '1.00';

=head1 SYNOPSIS

    use Email::Signature;
    my $msg = Mail::Message->new...

    # Footer text
    my $footer = {
        plain => "Plain footer text",
        html  => "<b>HTML footer</b>"
    }

    my $emailsig = Email::Signature->new({ footer => $footer });

    # Add some attachments
    # First an inline one
    $emailsig->attach {
        cid         = cid001@domain.com,
        file        = /var/emailsig/image1.jpeg,
        mimetype    = image/jpeg,
        disposition = inline,
    };

    # Now attached normally
    $emailsig->attach {
        file    = /var/emails/image2.jpeg,
        mimetype = image/jpeg,
    };

    $msg = $emailsig->sign($msg);

=head1 DESCRIPTION

Email::Signature is used to add a signature to emails. It tries to be as intelligent as possible. It attempts to position the signature as would be required by a normal user: for a reply that is top-posted, it tries to put it after the user's reply; for a bottom-posted or inline reply it adds it at the end.

Signatures can consist of HTML and plain text, plus attachments that can be either inline or normal attachments.

=cut

=head1 FUNCTIONS

=head2 new

C<new> creates a new Email::Signature. It takes an optional argument of a hash with the key 'footer', containing the footer as per C<footer>.

=cut

sub new($%)
{   my ($class, $options) = @_;
    my $self   = bless {}, $class;
    if ($options && $options->{footer})
    {
        footer($self, $options->{footer});
    }
    $self;
}

=head2 footer($hashref)

C<footer()> specifies the footer text for the signature. It takes a hashref, with the keys C<html> and C<plain>. HTML can include image tags that specify the content-IDs of images added later.

=cut

sub footer
{
    my $self = shift;
    if (my $footer = shift)
    {
        ref $footer eq 'HASH'
            or croak "footer() expects a hashref";
        foreach my $k (keys %$footer)
        {
            if ($k eq 'plain')
            {
                $self->{footer}->{plain} = $footer->{plain};
            }
            elsif($k eq 'html')
            {
                $self->{footer}->{html} = $footer->{html};
            }
            else
            {
                croak "Unknown key $k passed to footer(). Must be either plain or html.";
            }
        }
    }
    $self->{footer};
}

=head2 attach($hashref)

C<attach()> attaches a single file. It can be called multiple times to attach several files. It takes a hashref, which at a minimum must specify C<file> and C<mimetype> keys. In addition, it may also contain C<cid> and C<disposition> keys.

=cut

sub attach
{
    my ($self, $attach) = @_;
    $attach && ref $attach eq 'HASH'
        or croak "attach() expects a hashref";
    my $att;
    foreach my $k (keys %$attach)
    {
        if ($k eq 'cid')
        {
            $att->{$k} = "<$attach->{$k}>";
        }
        elsif ($k eq 'file' || $k eq 'mimetype' || $k eq 'disposition')
        {
            $att->{$k} = $attach->{$k};
        }
    }
    $att->{file} or croak "hashref must contain 'file' key to specify file to attach";
    $att->{mimetype} or croak "hashref must contain 'mimetype' key";

    my $attachments = $self->{attachments} || [];
    my @attachments = @$attachments;
    push @attachments, $att;
    $self->{attachments} = \@attachments;
    @attachments;
}

sub _add_attachments
{   my $attachments = shift;
    my $addatt = sub ($$@)
    {
        my ($msg, $part, %opts) = @_;

        # Add the attachments. These can either be inline, in which case
        # we add them to a multipart/related part. In this case, we only
        # add them here if there is an existing multipart/related part,
        # otherwise they are added in _add_footer, where a new multipart/related
        # is created.
        # If the attachment is not inline, then look for a top-level
        # multipart/mixed, or add one if it doesn't exist

        my @imgs;

        if ($part->toplevel && $part == $part->toplevel)
        {
            foreach my $att (@$attachments)
            {
                # See if it needs attaching to this related part
                next if ($att->{disposition} && $att->{disposition} eq 'inline') || $att->{done};
                my $img = _image($att);
                $att->{done} = 1;
                push @imgs, $img;
            }
            return $part unless @imgs;  # Nothing to add

            my $parts;
           
            if ($part->body->mimeType eq 'multipart/mixed')
            {
                $parts = [ $part->parts, @imgs ];
            }
            else
            {
                my $newbody = $part->body->clone;
                my $newpart = (ref $part)->new
                ( head      => $part->head->clone('X-Emailsig-Modified')
                , container => undef
                );
                $newpart->body($newbody);
                $part->head->delete('X-Emailsig-Modified');

                $parts = [ $newpart, @imgs ];
            }

            my $multi = Mail::Message::Body::Multipart->new(
                mime_type => 'multipart/mixed',
                parts     => $parts,
                preamble  => undef   # add some text?
            );
            $part->body($multi);
        }
        elsif($part->body->mimeType eq 'multipart/related')
        {
            foreach my $att (@$attachments)
            {
                # See if it needs attaching to this related part. This is tricky,
                # as it's difficult to know if this is the correct /related part.
                # Let's recurse into the parts and see if the text has the modified
                # headers
                my $addhere;
                foreach my $p ($part->parts)
                {
                    my @modified = $p->head->get('X-Emailsig-Modified')
                        or next; # Need list context for all headers
                    my $modified = join '', @modified;
                    $addhere = 1 if $modified =~ /footer_added_html/
                        or return $part;
                }
                if (!$att->{done} && $att->{addrelated} && $addhere) # && $att->{addrelated} eq refaddr($part->body))
                {
                    my $img = _image($att);
                    $att->{done} = 1;
                    push @imgs, $img;
                }
            }

            return $part unless @imgs;

            my $multi = Mail::Message::Body::Multipart->new(
                mime_type => 'multipart/related',
                parts     => [ $part->parts, @imgs ],
                preamble  => undef   # add some text?
            );
            $part->body($multi);
        }
        $part;
    };

    $addatt;
}

sub _add_footer
{
    my $footer      = shift;
    my $plain       = $footer->{plain} || '';
    my $html        = $footer->{html}  || '';
    my $attachments = shift;

    # XXX Update regex to match more languages and mail clients
    my $fromrx = 'From:\h+.*|On\h+.*\h+wrote:';

    my $need_plain = 1;
    my $wrap_text = sub ($$@)
    {
        my ($msg, $part, %opts) = @_;

        $need_plain or return $part; # Only add to first plain text part

        my @modified = $part->head->get('X-Emailsig-Modified'); # Need list context for all headers
        my $modified = join '', @modified;
        $modified !~ /footer_added_plain/
            or return $part;

        $part->body->mimeType eq 'text/plain'
            or return $part;

        # The mangled text should use the same transfer-encoding, usually
        # quoted-printable when lines are too long.
        my $decoded = $part->body->decoded;
        my $withsig = $decoded;

        # First test for "--" magic code.
        if ($withsig =~ s/^--$/$plain\n/mi)
        {
            $need_plain = 0;
        }

        unless ($decoded =~ /^($fromrx)\n/i) # Probably bottom-post or inline reply
        {
            if ($withsig =~ s/^($fromrx)$/$plain\n\n$1/im)
            {
                    $need_plain = 0;
            }
        }

        $withsig = "$decoded$plain\n\n"
            if $need_plain;

        my $newbody  = (ref $decoded)->new(
            based_on  => $decoded,
            data      => $withsig,
            transfer  => 'none'
        )->encode(
            transfer_encoding => $part->body->transferEncoding,
            charset   => $part->body->charset,
        );

        my $newpart  = (ref $part)->new(
            head      => $part->head->clone,
            container => undef,
        );
        $need_plain = 0;
        $newpart->body($newbody);
        $newpart->head->add('X-Emailsig-Modified' => 'footer_added_plain');
        $newpart;
    };

    my $need_html = 1;
    my $wrap_html = sub ($$@)
    {
        my ($msg, $part, %opts) = @_;

        $need_html or return $part; # Only add to first HTML part

        my @modified = $part->head->get('X-Emailsig-Modified'); # Need list context for all headers
        my $modified = join '', @modified;
        $modified !~ /footer_added_html/
            or return $part;

        $part->body->mimeType eq 'text/html'
            or return $part;

        my $decoded = $part->body->decoded;
        my $dom = Mojo::DOM->new($decoded);

        # First test for "--" magic code.
        if ($dom =~ s/^(.*\<br\>)?--(\<br\>.*)?$/$1$html$2/mi)
        {
            $need_html = 0;
        }
        elsif (my $blockquote = $dom->at('blockquote'))
        {
            # This is the start of the quoted email. Find the previous div
            my $ent = $blockquote;
            while ($ent = $ent->previous)
            {
                 if ($ent->type eq 'div' || $ent->type eq 'p')
                 {
                     $ent->prepend($html);
                     $need_html = 0;
                     last;
                 }
            }
            # We didn't find the content before the blockquote. Try again
            if ($need_html)
            {
                my $new = $blockquote->parent->content;
                unless ($new =~ /^($fromrx)(<br>)/i) # Probably bottom-post or inline reply
                {
                    if ($new =~ s/^($fromrx)/$html$1$2/im)
                    {
                        $blockquote->parent->content($new);
                        $need_html = 0;
                    }
                }
            }
        }

        # If not done, then probably no quoted text
        if ($need_html)
        {
            if (my $body = $dom->at('body'))
            {
                $dom = $body->append_content($html)->root;
            }
            elsif(my $h = $dom->at('html'))
            {
                $dom = $h->append_content($html)->root;
            }
            else
            {
                $dom = $dom.$html;
            }
        }

        my $newbody = (ref $decoded)->new(
            based_on  => $decoded,
            data      => "$dom",   # Force stringify
        )->encode(
            transfer_encoding => $part->body->transferEncoding,
            charset   => $part->body->charset,
        );

        my $newpart = (ref $part)->new(
            head      => $part->head->clone,
            container => undef,
        );

        $newpart->body($newbody);
        $newpart->head->add('X-Emailsig-Modified' => 'footer_added_html');

        my $parent = $part->container; my $multi;
        if($parent && $parent->mimeType eq 'multipart/related')
        {
            # Parent is a multipart/related, so we need to add the
            # attachments to that multipart. We can't do that now
            # though, so flag them for adding and return the part
            foreach my $att (@$attachments)
            {
                # See if it's already been attached and check it's inline
                next if !$att->{disposition} || $att->{disposition} ne 'inline' || $att->{done};
                $att->{addrelated} = 1;
            }

            $newpart;
        }
        else
        {
            # The inline attachments, normally images. Create a new multipart/related
            # with the images in, and use that to replace the current part
            my @imgs;
            foreach my $att (@$attachments)
            {
                # See if it's already been attached and check it's inline
                next if !$att->{disposition} || $att->{disposition} ne 'inline' || $att->{done};
                my $img = _image($att);
                $att->{done} = 1;
                push @imgs, $img;
            }

            return $newpart unless @imgs; # No images to add

            # Create another new part with headers. We can't use the whole
            # part next or we get recursion. We can't just use the body
            # otherwise the X- header is missing
            my $newpart2 = (ref $newpart)->new
            ( head      => $newpart->head->clone('X-Emailsig-Modified')
            , container => undef
            );
            $newpart2->body($newpart->body);
            $newpart->head->delete('X-Emailsig-Modified'); # Delete modified header from multipart

            my $multi = Mail::Message::Body::Multipart->new(
                mime_type => 'multipart/related',
                parts     => [ $newpart2, @imgs ],
                preamble  => undef,   # add some text?
            );
            $newpart->body($multi);
            $newpart;
        }
    };

    ($wrap_text, $wrap_html);

}

sub _image
{   my $img = shift;
    my $i = {
        file => $img->{file},
        mimetype => $img->{mimetype},
    };
    $i->{disposition} = $img->{disposition} if $img->{disposition};
    $i->{content_id} = $img->{cid} if $img->{cid};

    Mail::Message::Body::Lines->new(
        %$i
    )->encode(
        transfer_encoding => 'base64',
    );
}

=head2 sign(Mail::Message)

C<sign()> adds the previously defined signature to a Mail::Message. It returns the Mail::Message object with the signature added.

=cut

sub sign
{   my ($self, $msg) = @_;
    my $footer       = $self->{footer};
    my $attachments  = $self->{attachments};

    confess "sign must be called with a Mail::Message object reference"
        unless ref $msg and $msg->isa('Mail::Message');

    # Attachments can be added in 2 places:
    # - When the signature text is added, for inline images in HTML
    #   content and when a new multipart/related needs to be added
    # - After the sig has been added, to an existing multipart/related
    #   or to a new or existing multipart/mixed
    my @extra_rules;
    push @extra_rules, _add_attachments $attachments;
    push @extra_rules, _add_footer $footer, $attachments;

    my $rebuild = $msg->rebuild(
        keep_message_id => 1,
        extra_rules     => \@extra_rules,
    );

    $rebuild;
}

=head1 CAVEATS

Attempting to find the correct place to insert the footer is difficult. Only a limited number of email clients and languages have been provisioned for and tested. Please help by providing patches for better support.

=head1 BUGS

Please use the libemail-signature-perl Github page.

=head1 SUPPORT

Please use the libemail-signature-perl Github page.

=head1 COPYRIGHT & LICENCE

Copyright 2014 Ctrl O Ltd

You may distribute this code under the same terms as Perl itself.

=cut

1; # End of Email::Signature

