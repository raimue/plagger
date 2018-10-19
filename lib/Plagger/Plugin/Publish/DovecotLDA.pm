package Plagger::Plugin::Publish::DovecotLDA;
use strict;
use base qw( Plagger::Plugin );

use DateTime;
use DateTime::Format::Mail;
use Encode qw/ from_to encode/;
use Encode::MIME::Header;
use HTML::Entities;
use MIME::Lite;
use Digest::MD5 qw/ md5_hex /;
use File::Find;
use IPC::Open3;

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'plugin.init'      => \&initialize,
        'publish.entry'    => \&store_entry,
        'publish.finalize' => \&finalize,
    );
}

sub rule_hook { 'publish.entry' }

sub initialize {
    my($self, $context, $args) = @_;
    my $cfg = $self->conf;
    if (-d $cfg->{home}) {
        $self->{home} = $cfg->{home};
    } else {
        die $context->log(error => "Could not access $cfg->{home}");
    }
    my $bin = ${cfg}->{dovecot_lda} || "/usr/lib/dovecot/dovecot-lda";
    if (-x $bin) {
        $self->{bin} = $bin;
    } else {
        die $context->log(error => "Could not find usable dovecot-lda at $cfg->{dovecot_lda}");
    }
}

sub finalize {
    my($self, $context, $args) = @_;
    if (my $msg_count = $self->{msg}) {
        if (my $update_count = $self->{update_msg}) {
            $context->log(info =>
"Store $msg_count message(s) ($update_count message(s) updated)"
            );
        }
        else {
            $context->log(info => "Store $msg_count message(s)");
        }
    }
}

sub store_entry {
    my($self, $context, $args) = @_;
    my $cfg = $self->conf;
    my $msg;
    my $entry      = $args->{entry};
    my $feed_title = $args->{feed}->title->plaintext;
    my $from_name = $feed_title;
    my $subject = $entry->title->plaintext || '(no-title)';
    my $mailbox = $args->{feed}->meta->{mailbox} || "";
    my $body = $self->templatize('mail.tt', $args);
    $body = encode("utf-8", $body);
    my $from = $cfg->{mailfrom} || 'plagger@localhost';
    my $id   = md5_hex($entry->id_safe);
    my $date = $entry->date || Plagger::Date->now(timezone => $context->conf->{timezone});
    my @enclosure_cb;

    if ($self->conf->{attach_enclosures}) {
        push @enclosure_cb, $self->prepare_enclosures($entry);
    }
    $msg = MIME::Lite->new(
        Date    => $date->format('Mail'),
        From    => encode('MIME-Header', "X: " . $from_name . " <$from>") =~ s/X: //r,
        To      => $cfg->{mailto},
        Subject => encode('MIME-Header', "X: " . $subject) =~ s/X: //r,
        Type    => 'multipart/related',
    );
    $msg->attach(
        Type     => 'text/html; charset=utf-8',
        Data     => $body,
        Encoding => 'quoted-printable',
    );
    for my $cb (@enclosure_cb) {
        $cb->($msg);
    }
    $msg->add('Message-Id', "<$id.plagger\@localhost>");
    $msg->add('X-Tags', encode('MIME-Header', "X: " . join(' ', @{ $entry->tags }) =~ s/X: //r));
    my $xmailer = "Plagger/$Plagger::VERSION";
    $msg->replace('X-Mailer', $xmailer);
    deliver($self, $context, $msg->as_string(), $mailbox, $id);
    $self->{msg} += 1;
}

sub prepare_enclosures {
    my($self, $entry) = @_;

    if (grep $_->is_inline, $entry->enclosures) {

        # replace inline enclosures to cid: entities
        my %url2enclosure = map { $_->url => $_ } $entry->enclosures;

        my $output;
        my $p = HTML::Parser->new(api_version => 3);
        $p->handler(default => sub { $output .= $_[0] }, "text");
        $p->handler(
            start => sub {
                my($tag, $attr, $attrseq, $text) = @_;

                # TODO: use HTML::Tagset?
                if (my $url = $attr->{src}) {
                    if (my $enclosure = $url2enclosure{$url}) {
                        $attr->{src} = "cid:" . $self->enclosure_id($enclosure);
                    }
                    $output .= $self->generate_tag($tag, $attr, $attrseq);
                }
                else {
                    $output .= $text;
                }
            },
            "tag, attr, attrseq, text"
        );
        $p->parse($entry->body);
        $p->eof;

        $entry->body($output);
    }

    return sub {
        my $msg = shift;

        for my $enclosure (grep $_->local_path, $entry->enclosures) {
            if (!-e $enclosure->local_path) {
                Plagger->context->log(warning => $enclosure->local_path .  " doesn't exist.  Skip");
                next;
            }

            my %param = (
                Type     => $enclosure->type,
                Path     => $enclosure->local_path,
                Filename => $enclosure->filename,
            );

            if ($enclosure->is_inline) {
                $param{Id} = '<' . $self->enclosure_id($enclosure) . '>';
                $param{Disposition} = 'inline';
            }
            else {
                $param{Disposition} = 'attachment';
            }

            $msg->attach(%param);
        }
      }
}

sub generate_tag {
    my($self, $tag, $attr, $attrseq) = @_;

    return "<$tag " . join(
        ' ',
        map {
            $_ eq '/' ? '/' : sprintf qq(%s="%s"), $_,
              encode_entities($attr->{$_}, q(<>"'))
          } @$attrseq
      )
      . '>';
}

sub enclosure_id {
    my($self, $enclosure) = @_;
    return Digest::MD5::md5_hex($enclosure->url->as_string) . '@Plagger';
}

sub deliver {
    my($self, $context, $msg, $subfolder, $id) = @_;
    my $home = $self->{home};
    my $bin = $self->{bin};
    my $extra_args = $self->conf->{extra_args};
    my $folder = $self->conf->{folder};
    my $separator = $self->conf->{separator};

    my $cmd = "HOME=\"$home\" \"$bin\"";
    if ($self->conf->{create_subfolders} && $subfolder ne "") {
        $cmd .= " -m \"$folder$separator$subfolder\"";
        $cmd .= " -o lda_mailbox_autocreate=yes";
    } else {
        $cmd .= " -m \"$folder\"";
    }
    $cmd .= " $extra_args";

    $context->log(debug => "executing: $cmd");
    my $pid = open3(\*CHLD_IN, \*CHLD_OUT, \*CHLD_ERR, $cmd)
        or $context->error("open3($cmd): $!");

    print CHLD_IN $msg;
    close CHLD_IN;

    waitpid($pid, 0);
    my $status = $? >> 8;
    if ($status != 0) {
        $context->error("dovecot-lda returned: $status");
    }
}

1;

=head1 NAME

Plagger::Plugin::Publish::DovecotLDA - Deliver with dovecot-lda

=head1 SYNOPSIS

  - module: Subscription::Config
    config:
      feed:
        - url: https://m.xkcd.com/atom.xml
          link: http://xkcd.com/
          meta: { mailbox: "Comics.xkcd" }

  - module: Publish::DovecotLDA 
    config:
      home: /home/foo
      folder: plagger
      separator: .
      dovecot_lda: /usr/lib/dovecot/dovecot-lda
      extra_args: -o maildir:~/mail.fs:LAYOUT=fs
      create_subfolders: 0
      attach_enclosures: 1
      mailfrom: plagger@localhost

=head1 DESCRIPTION

This plugin changes an entry into e-mail, and delivers it locally with dovecot-lda.

=head1 AUTHOR

Nobuhito Sato
Rainer Müller

=head1 SEE ALSO

L<Plagger>

=cut

