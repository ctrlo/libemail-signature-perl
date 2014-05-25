use ExtUtils::MakeMaker;
 
WriteMakefile(
    NAME            => 'Email::Signature',
    VERSION_FROM    => 'lib/Email/Signature.pm',
    AUTHOR          => 'Andy Beverley <a.beverley@ctrlo.com>',
    ABSTRACT        => 'Adds a signature and attachments to a Mail::Message object',
    PREREQ_PM => {
        "Mojo::DOM"     => 0,
        "Mail::Message" => 0,
        "Mail::Message::Body::Lines" => 0,
    }
);

