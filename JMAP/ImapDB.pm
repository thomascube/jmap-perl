#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::ImapDB;
use base qw(JMAP::DB);

use DBI;
use Date::Parse;
use JSON::XS qw(decode_json);
use Data::UUID::LibUUID;
use OAuth2::Tiny;
use Digest::SHA qw(sha1_hex);
use Encode;
use Encode::MIME::Header;
use Encode::IMAPUTF7;
use AnyEvent;
use AnyEvent::Socket;
use Date::Format;
use Data::Dumper;
use JMAP::Sync::Gmail;
use JMAP::Sync::Standard;

my $json = JSON::XS->new->utf8->canonical();

our $TAG = 1;

# special use or name magic
my %ROLE_MAP = (
  'inbox' => 'inbox',

  'drafts' => 'drafts',
  'draft' => 'drafts',
  'draft messages' => 'drafts',

  'bulk' => 'spam',
  'bulk mail' => 'spam',
  'junk' => 'spam',
  'junk mail' => 'spam',
  'spam' => 'spam',
  'spam mail' => 'spam',
  'spam messages' => 'spam',

  'archive' => 'archive',
  'sent' => 'sent',
  'sent items' => 'sent',
  'sent messages' => 'sent',

  'deleted messages' => 'trash',
  'trash' => 'trash',

  '\\inbox' => 'inbox',
  '\\trash' => 'trash',
  '\\sent' => 'sent',
  '\\junk' => 'spam',
  '\\spam' => 'spam',
  '\\archive' => 'archive',
  '\\drafts' => 'drafts',
);

sub setuser {
  my $Self = shift;
  my $args = shift;
  # XXX - picture, etc

  $Self->begin();

  my $data = $Self->dgetone('iserver');
  if ($data) {
    $Self->dmaybeupdate('iserver', $args);
  }
  else {
    $Self->dinsert('iserver', $args);
  }

  my $user = $Self->dgetone('account');
  if ($user) {
    $Self->dmaybeupdate('account', {email => $args->{username}});
  }
  else {
    $Self->dinsert('account', {
      email => $args->{username},
      jdeletedmodseq => 0,
      jhighestmodseq => 1,
    });
  }

  $Self->commit();
}

sub access_token {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dgetone('iserver');
  $Self->commit();

  return [$data->{imapHost}, $data->{username}, $data->{password}];
}

sub access_data {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dgetone('iserver');
  $Self->commit();

  return $data;
}

# synchronous backend for now
sub backend_cmd {
  my $Self = shift;
  my $cmd = shift;
  my @args = @_;

  use Carp;
  Carp::confess("in transaction") if $Self->in_transaction();

  unless ($Self->{backend}) {
    my $config = $Self->access_data();
    my $backend;
    if ($config->{imapHost} eq 'imap.gmail.com') {
      $backend = JMAP::Sync::Gmail->new($config) || die "failed to setup $config->{username}";
    } elsif ($config->{imapHost} eq 'imap.aol.com') {
      $backend = JMAP::Sync::AOL->new($config) || die "failed to setup $config->{username}";
    } else {
      $backend = JMAP::Sync::Standard->new($config) || die "failed to setup $config->{username}";
    }
    $Self->{backend} = $backend;
  }

  die "No such command $cmd" unless $Self->{backend}->can($cmd);
  return $Self->{backend}->$cmd(@args);
}

# synchronise list from IMAP server to local folder cache
# call in transaction
sub sync_folders {
  my $Self = shift;

  my $data = $Self->backend_cmd('folders');
  my ($prefix, $folders) = @$data;

  $Self->begin();

  my $ifolders = $Self->dget('ifolders');
  my %ibylabel = map { $_->{label} => $_ } @$ifolders;
  my %seen;

  my %getstatus;
  my %getuniqueid;
  foreach my $name (sort keys %$folders) {
    my $sep = $folders->{$name}[0];
    my $label = $folders->{$name}[1];
    my $id = $ibylabel{$label}{ifolderid};
    if ($id) {
      $Self->dmaybeupdate('ifolders', {sep => $sep, imapname => $name}, {ifolderid => $id});
    }
    else {
      $id = $Self->dinsert('ifolders', {sep => $sep, imapname => $name, label => $label});
    }
    $seen{$id} = 1;
    unless ($ibylabel{$label}{uidvalidity}) {
      # no uidvalidity, we need to get status for this one
      $getstatus{$name} = $id;
    }
    unless ($ibylabel{$label}{uniqueid}) {
      $getuniqueid{$name} = $id;
    }
  }

  foreach my $folder (@$ifolders) {
    my $id = $folder->{ifolderid};
    next if $seen{$id};
    $Self->ddelete('ifolders', {ifolderid => $id});
  }

  $Self->dmaybeupdate('iserver', {imapPrefix => $prefix, lastfoldersync => time()});

  $Self->commit();

  if (keys %getstatus) {
    my $data = $Self->backend_cmd('imap_status', [keys %getstatus]);
    $Self->begin();
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      next unless ref($status) eq 'HASH';
      $Self->dmaybeupdate('ifolders', {
        uidvalidity => $status->{uidvalidity},
        uidnext => $status->{uidnext},
        uidfirst => $status->{uidnext},
        highestmodseq => $status->{highestmodseq},
      }, {ifolderid => $getstatus{$name}});
    }
    $Self->commit();
  }

  if (keys %getuniqueid) {
    my $data = $Self->backend_cmd('imap_getuniqueid', [keys %getuniqueid]);
    $Self->begin();
    foreach my $name (keys %$data) {
      my $status = $data->{$name};
      next unless ref($status) eq 'HASH';
      eval { $Self->dmaybeupdate('ifolders', {
        uniqueid => $status->{'/vendor/cmu/cyrus-imapd/uniqueid'},
      }, {ifolderid => $getstatus{$name}}); };
    }
    $Self->commit();
  }

  $Self->sync_jmailboxes();
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jmailboxes {
  my $Self = shift;
  $Self->begin();
  my $ifolders = $Self->dget('ifolders');
  my $jmailboxes = $Self->dget('jmailboxes');

  my %jbyid;
  my %roletoid;
  my %byname;
  foreach my $mailbox (@$jmailboxes) {
    $jbyid{$mailbox->{jmailboxid}} = $mailbox;
    $roletoid{$mailbox->{role}} = $mailbox->{jmailboxid} if $mailbox->{role};
    $byname{$mailbox->{parentId}}{$mailbox->{name}} = $mailbox->{jmailboxid};
  }

  my %seen;
  foreach my $folder (@$ifolders) {
    next if lc $folder->{label} eq "\\allmail"; # we don't show this folder
    my $fname = $folder->{imapname};
    # check for roles first
    my @bits = map { decode('IMAP-UTF-7', $_) } split "[$folder->{sep}]", $fname;
    shift @bits if ($bits[0] eq 'INBOX' and $bits[1]); # really we should be stripping the actual prefix, if any
    shift @bits if $bits[0] eq '[Gmail]'; # we special case this GMail magic
    next unless @bits; # also skip the magic '[Gmail]' top-level
    my $role = $ROLE_MAP{lc $folder->{label}};
    my $id = '';
    my $parentId = '';
    my $name;
    my $sortOrder = 3;
    $sortOrder = 2 if $role;
    $sortOrder = 1 if ($role||'') eq 'inbox';
    while (my $item = shift @bits) {
      $seen{$id} = 1 if $id;
      $name = $item;
      $parentId = $id;
      $id = $byname{$parentId}{$name};
      unless ($id) {
        if (@bits) {
          # need to create intermediate folder ...
          # XXX  - label noselect?
          $id = new_uuid_string();
          $Self->dmake('jmailboxes', {name => $name, jmailboxid => $id, sortOrder => 4, parentId => $parentId});
          $byname{$parentId}{$name} = $id;
        }
      }
    }
    next unless $name;
    my %details = (
      name => $name,
      parentId => $parentId,
      sortOrder => $sortOrder,
      mustBeOnlyMailbox => 0,
      mayReadItems => 1,
      mayAddItems => 1,
      mayRemoveItems => 1,
      mayCreateChild => 1,
      mayRename => $role ? 0 : 1,
      mayDelete => $role ? 0 : 1,
    );
    if ($id) {
      if ($role and $roletoid{$role} and $roletoid{$role} ne $id) {
        # still gotta move it
        $id = $roletoid{$role};
        $Self->dmaybedirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id});
      }
      elsif (not $folder->{active}) {
        # reactivate!
        $Self->dmaybedirty('jmailboxes', {active => 1}, {jmailboxid => $id});
      }
    }
    else {
      # case: role - we need to see if there's a case for moving this thing
      if ($role and $roletoid{$role}) {
        $id = $roletoid{$role};
        $Self->dmaybedirty('jmailboxes', {active => 1, %details}, {jmailboxid => $id});
      }
      else {
        $id = $folder->{uniqueid} || new_uuid_string();
        $Self->dmake('jmailboxes', {role => $role, jmailboxid => $id, %details});
        $byname{$parentId}{$name} = $id;
        $roletoid{$role} = $id if $role;
      }
    }
    $seen{$id} = 1;
    $Self->dmaybeupdate('ifolders', {jmailboxid => $id}, {ifolderid => $folder->{ifolderid}});
  }

  foreach my $mailbox (@$jmailboxes) {
    my $id = $mailbox->{jmailboxid};
    next unless $mailbox->{active};
    next if $seen{$id};
    $Self->dupdate('jmailboxes', {active => 0}, {jmailboxid => $id});
  }

  $Self->commit();
}

# synchronise list from CalDAV server to local folder cache
sub sync_calendars {
  my $Self = shift;

  my $calendars = $Self->backend_cmd('get_calendars', []);
  return unless $calendars;

  $Self->begin();

  my $icalendars = $Self->dget('icalendars');
  my %byhref = map { $_->{href} => $_ } @$icalendars;

  my %seen;
  my %todo;
  foreach my $calendar (@$calendars) {
    my $id = $calendar->{href} ? $byhref{$calendar->{href}}{icalendarid} : 0;
    my $data = {
      isReadOnly => $calendar->{isReadOnly},
      href => $calendar->{href},
      color => $calendar->{color},
      name => $calendar->{name},
      syncToken => $calendar->{syncToken},
    };
    if ($id) {
      $Self->dmaybeupdate('icalendars', $data, {icalendarid => $id});
      my $token = $byhref{$calendar->{href}}{syncToken};
      if ($token && $token eq $calendar->{syncToken}) {
        $seen{$id} = 1;
        next;
      }
    }
    else {
      $id = $Self->dinsert('icalendars', $data);
    }
    $todo{$id} = $calendar->{href};
    $seen{$id} = 1;
  }

  foreach my $calendar (@$icalendars) {
    my $id = $calendar->{icalendarid};
    next if $seen{$id};
    $Self->ddelete('icalendars', {icalendarid => $id});
  }

  $Self->sync_jcalendars();

  $Self->commit();

  $Self->do_calendars(\%todo);
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jcalendars {
  my $Self = shift;

  my $icalendars = $Self->dget('icalendars');
  my $jcalendars = $Self->dget('jcalendars');

  my %jbyid;
  foreach my $calendar (@$jcalendars) {
    $jbyid{$calendar->{jcalendarid}} = $calendar;
  }

  my %seen;
  foreach my $calendar (@$icalendars) {
    my $data = {
      name => $calendar->{name},
      color => $calendar->{color},
      isVisible => 1,
      mayReadFreeBusy => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 1,
      mayRename => 1,
    };
    my $id = $calendar->{jcalendarid};
    if ($id && $jbyid{$id}) {
      $Self->dmaybedirty('jcalendars', $data, {jcalendarid => $id});
    }
    else {
      $id = $Self->dmake('jcalendars', $data);
      $Self->dupdate('icalendars', {jcalendarid => $id}, {icalendarid => $calendar->{icalendarid}});
    }
    $seen{$id} = 1;
  }

  foreach my $calendar (@$jcalendars) {
    my $id = $calendar->{jcalendarid};
    next if $seen{$id};
    $Self->dnuke('jcalendars', {jcalendarid => $id});
    $Self->dnuke('jevents', {jcalendarid => $id});
  }
}

sub do_calendars {
  my $Self = shift;
  my $cals = shift;

  my %allparsed;
  my %allevents;
  foreach my $href (sort values %$cals) {
    my $events = $Self->backend_cmd('get_events', $href);
    # parse events before we lock
    my %parsed = map { $_ => $Self->parse_event($events->{$_}) } keys %$events;
    $allparsed{$href} = \%parsed;
    $allevents{$href} = $events;
  }

  $Self->begin();
  foreach my $id (keys %$cals) {
    my $href = $cals->{$id};
    my ($jcalendarid) = $Self->dbh->selectrow_array("SELECT jcalendarid FROM icalendars WHERE icalendarid = ?", {}, $id);
    my $exists = $Self->dget('ievents', {icalendarid => $id});
    my %res = map { $_->{resource} => $_ } @$exists;

    foreach my $resource (keys %{$allparsed{$href}}) {
      my $data = delete $res{$resource};
      my $raw = $allevents{$href}{$resource};
      my $event = $allparsed{$href}{$resource};
      my $uid = $event->{uid};
      my $item = {
        icalendarid => $id,
        uid => $uid,
        resource => $resource,
        content => encode_utf8($raw),
      };
      if ($data) {
        my $eid = $data->{ieventid};
        next if $raw eq decode_utf8($data->{content});
        $Self->dmaybeupdate('ievents', $item, {ieventid => $eid});
      }
      else {
        $Self->dinsert('ievents', $item);
      }
      $Self->set_event($jcalendarid, $event);
    }

    foreach my $resource (keys %res) {
      my $data = delete $res{$resource};
      my $id = $data->{ieventid};
      $Self->ddelete('ievents', {ieventid => $id});
      $Self->delete_event($jcalendarid, $data->{uid});
    }
  }

  $Self->commit();
}

# synchronise list from CardDAV server to local folder cache
# call in transaction
sub sync_addressbooks {
  my $Self = shift;

  my $addressbooks = $Self->backend_cmd('get_addressbooks', []);
  return unless $addressbooks;

  $Self->begin();

  my $iaddressbooks = $Self->dget('iaddressbooks');
  my %byhref = map { $_->{href} => $_ } @$iaddressbooks;

  my %seen;
  my %todo;
  foreach my $addressbook (@$addressbooks) {
    my $id = $byhref{$addressbook->{href}}{iaddressbookid};
    my $data = {
      isReadOnly => $addressbook->{isReadOnly},
      href => $addressbook->{href},
      name => $addressbook->{name},
      syncToken => $addressbook->{syncToken},
    };
    if ($id) {
      $Self->dmaybeupdate('iaddressbooks', $data, {iaddressbookid => $id});
      my $token = $byhref{$addressbook->{href}}{syncToken};
      if ($token && $token eq $addressbook->{syncToken}) {
        $seen{$id} = 1;
        next;
      }
    }
    else {
      $id = $Self->dinsert('iaddressbooks', $data);
    }
    $todo{$id} = $addressbook->{href};
    $seen{$id} = 1;
  }

  foreach my $addressbook (@$iaddressbooks) {
    my $id = $addressbook->{iaddressbookid};
    next if $seen{$id};
    $Self->ddelete('iaddressbooks', {iaddressbookid => $id});
  }

  $Self->sync_jaddressbooks();

  $Self->commit();

  $Self->do_addressbooks(\%todo);
}

# synchronise from the imap folder cache to the jmap mailbox listing
# call in transaction
sub sync_jaddressbooks {
  my $Self = shift;

  my $iaddressbooks = $Self->dget('iaddressbooks');
  my $jaddressbooks = $Self->dget('jaddressbooks');

  my %jbyid;
  foreach my $addressbook (@$jaddressbooks) {
    next unless $addressbook->{jaddressbookid};
    $jbyid{$addressbook->{jaddressbookid}} = $addressbook;
  }

  my %seen;
  foreach my $addressbook (@$iaddressbooks) {
    my $aid = $addressbook->{iaddressbookid};
    my $data = {
      name => $addressbook->{name},
      isVisible => 1,
      mayReadItems => 1,
      mayAddItems => 1,
      mayModifyItems => 1,
      mayRemoveItems => 1,
      mayDelete => 0,
      mayRename => 0,
    };
    my $jid = $addressbook->{jaddressbookid};
    if ($jid && $jbyid{$jid}) {
      $Self->dmaybedirty('jaddressbooks', $data, {jaddressbookid => $jid});
      $seen{$jid} = 1;
    }
    else {
      $jid = $Self->dmake('jaddressbooks', $data);
      $Self->dupdate('iaddressbooks', {jaddressbookid => $jid}, {iaddressbookid => $aid});
      $seen{$jid} = 1;
    }
  }

  foreach my $addressbook (@$jaddressbooks) {
    my $jid = $addressbook->{jaddressbookid};
    next if $seen{$jid};
    $Self->dnuke('jaddressbooks', {jaddressbookid => $jid});
    $Self->dnuke('jcontactgroups', {jaddressbookid => $jid});
    $Self->dnuke('jcontacts', {jaddressbookid => $jid});
  }
}

sub do_addressbooks {
  my $Self = shift;
  my $books = shift;

  my %allcards;
  my %allparsed;
  foreach my $href (sort values %$books) {
    my $cards = $Self->backend_cmd('get_cards', $href);
    # parse before locking
    my %parsed = map { $_ => $Self->parse_card($cards->{$_}) } keys %$cards;
    $allparsed{$href} = \%parsed;
    $allcards{$href} = $cards;
  }

  $Self->begin();

  foreach my $id (keys %$books) {
    my $href = $books->{$id};
    my ($jaddressbookid) = $Self->dbh->selectrow_array("SELECT jaddressbookid FROM iaddressbooks WHERE iaddressbookid = ?", {}, $id);
    my $exists = $Self->dget('icards', {iaddressbookid => $id});
    my %res = map { $_->{resource} => $_ } @$exists;

    foreach my $resource (keys %{$allparsed{$href}}) {
      my $data = delete $res{$resource};
      my $raw = $allcards{$href}{$resource};
      my $card = $allparsed{$href}{$resource};
      my $uid = $card->{uid};
      my $kind = $card->{kind};
      my $item = {
        iaddressbookid => $id,
        resource => $resource,
        uid => $uid,
        kind => $kind,
        content => encode_utf8($raw),
      };
      if ($data) {
        my $cid = $data->{icardid};
        next if $raw eq decode_utf8($data->{content});
        $Self->dmaybeupdate('icards', $item, {icardid => $cid});
      }
      else {
        $Self->dinsert('icards', $item);
      }
      $Self->set_card($jaddressbookid, $card);
    }

    foreach my $resource (keys %res) {
      my $data = delete $res{$resource};
      my $cid = $data->{icardid};
      $Self->ddelete('icards', {icardid => $cid});
      $Self->delete_card($jaddressbookid, $data->{uid}, $data->{kind});
    }
  }

  $Self->commit();
}

sub labels {
  my $Self = shift;

  my $data = $Self->dget('ifolders');
  return { map { $_->{label} => [$_->{ifolderid}, $_->{jmailboxid}, $_->{imapname}] } @$data };
}

sub sync_imap {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dget('ifolders');
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }
  $Self->commit();

  my @imapnames = map { $_->{imapname} } @$data;
  my $status = $Self->backend_cmd('imap_status', \@imapnames);

  foreach my $row (@$data) {
    # XXX - better handling of UIDvalidity change?
    next if ($status->{$row->{imapname}}{uidvalidity} == $row->{uidvalidity} and $status->{$row->{imapname}}{highestmodseq} and $status->{$row->{imapname}}{highestmodseq} == $row->{highestmodseq});
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $Self->do_folder($row->{ifolderid}, $label);
  }

  $Self->sync_jmap();
}

sub backfill {
  my $Self = shift;

  $Self->begin();
  my $data = $Self->dbh->selectall_arrayref("SELECT * FROM ifolders WHERE uidnext > 1 AND uidfirst > 1 ORDER BY mtime", {Slice => {}});
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }
  $Self->commit();

  return unless @$data;

  #DB::enable_profile();
  my $rest = 500;
  foreach my $row (@$data) {
    my $id = $row->{ifolderid};
    my $label = $row->{label};
    $label = undef if lc $label eq '\\allmail';
    $rest -= $Self->do_folder($id, $label, $rest);
    last if $rest < 10;
  }
  #DB::disable_profile();
  #exit 0;

  $Self->sync_jmap();

  return 1;
}

sub firstsync {
  my $Self = shift;

  $Self->sync_folders();

  $Self->begin();
  my $data = $Self->dget('ifolders');
  $Self->commit();

  if ($Self->{is_gmail}) {
    my ($folder) = grep { lc $_->{label} eq '\\allmail' } @$data;
    $Self->do_folder($folder->{ifolderid}, undef, 50) if $folder;
  }
  else {
    my ($folder) = grep { lc $_->{imapname} eq 'inbox' } @$data;
    $Self->do_folder($folder->{ifolderid}, $folder->{label}, 50) if $folder;
  }

  $Self->sync_jmap();
}

sub _trimh {
  my $val = shift;
  return '' unless defined $val;
  $val =~ s{\s+$}{};
  $val =~ s{^\s+}{};
  return $val;
}

sub calclabels {
  my $Self = shift;
  my $forcelabel = shift;
  my $data = shift;

  return ($forcelabel) if $forcelabel;
  return (@{$data->{'x-gm-labels'}}) if $data->{'x-gm-labels'};
  die "No way to calculate labels for " . Dumper($data);
}

sub calcmsgid {
  my $Self = shift;
  my $imapname = shift;
  my $uid = shift;
  my $data = shift;

  return ($data->{"x-gm-msgid"}, $data->{"x-gm-thrid"})
    if ($data->{"x-gm-msgid"} and $data->{"x-gm-thrid"});

  return ($data->{"digest.sha1"}, $data->{"cid"})
    if ($data->{"digest.sha1"} and $data->{"cid"});

  my $envelope = $data->{envelope};
  my $coded = $json->encode([$envelope]);
  my $base = substr(sha1_hex($coded), 0, 9);
  my $msgid = "m$base";

  my $replyto = _trimh($envelope->{'In-Reply-To'});
  my $messageid = _trimh($envelope->{'Message-ID'});
  my $encsub = eval { Encode::decode('MIME-Header', $envelope->{Subject}) };
  $encsub = $envelope->{Subject} unless defined $encsub;
  my $sortsub = _normalsubject($encsub);
  my ($thrid) = $Self->dbh->selectrow_array("SELECT DISTINCT thrid FROM ithread WHERE messageid IN (?, ?) AND sortsubject = ?", {}, $replyto, $messageid, $sortsub);
  # XXX - merging?  subject-checking?  We have a subject here
  $thrid ||= "t$base";
  foreach my $id ($replyto, $messageid) {
    next if $id eq '';
    $Self->dbh->do("INSERT OR IGNORE INTO ithread (messageid, thrid, sortsubject) VALUES (?, ?, ?)", {}, $id, $thrid, $sortsub);
  }

  return ($msgid, $thrid);
}

sub do_folder {
  my $Self = shift;
  my $ifolderid = shift;
  my $forcelabel = shift;
  my $batchsize = shift;

  Carp::confess("NO FOLDERID") unless $ifolderid;
  $Self->begin();

  my $data = $Self->dgetone('ifolders', {ifolderid => $ifolderid});
  die "NO SUCH FOLDER $ifolderid" unless $data;
  my $imapname = $data->{imapname};
  my $uidfirst = $data->{uidfirst};
  my $uidvalidity = $data->{uidvalidity};
  my $uidnext = $data->{uidnext};
  my $highestmodseq = $data->{highestmodseq};

  my %fetches;

  if ($batchsize) {
    if ($uidfirst > 1) {
      my $end = $uidfirst - 1;
      $uidfirst -= $batchsize;
      $uidfirst = 1 if $uidfirst < 1;
      $fetches{backfill} = [$uidfirst, $end, 1];
    }
  }
  else {
    $fetches{new} = [$uidnext, '*', 1];
    $fetches{update} = [$uidfirst, $uidnext - 1, 0, $highestmodseq];
  }

  $Self->commit();

  return unless keys %fetches;

  my $res = $Self->backend_cmd('imap_fetch', $imapname, {
    uidvalidity => $uidvalidity,
    highestmodseq => $highestmodseq,
    uidnext => $uidnext,
  }, \%fetches);

  if ($res->{newstate}{uidvalidity} != $uidvalidity) {
    # going to want to nuke everything for the existing folder and create this - but for now, just die
    die "UIDVALIDITY CHANGED $imapname: $uidvalidity => $res->{newstate}{uidvalidity}";
  }

  $Self->begin();
  $Self->{t}{backfilling} = 1 if $batchsize;

  my $didold = 0;
  if ($res->{backfill}) {
    my $new = $res->{backfill}[1];
    my $count = 0;
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      $count++;
      # release the lock frequently so we don't starve the API
      if ($count > 50) {
        $Self->commit();
        $Self->begin();
        $Self->{t}{backfilling} = 1;
        $count = 0;
      }
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      my @labels = $Self->calclabels($forcelabel, $new->{$uid});
      $didold++;
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  if ($res->{update}) {
    my $changed = $res->{update}[1];
    foreach my $uid (sort { $a <=> $b } keys %$changed) {
      my @labels = $Self->calclabels($forcelabel, $changed->{$uid});
      $Self->changed_record($ifolderid, $uid, $changed->{$uid}{'flags'}, \@labels);
    }
  }

  if ($res->{new}) {
    my $new = $res->{new}[1];
    foreach my $uid (sort { $a <=> $b } keys %$new) {
      my ($msgid, $thrid) = $Self->calcmsgid($imapname, $uid, $new->{$uid});
      my @labels = $Self->calclabels($forcelabel, $new->{$uid});
      $Self->new_record($ifolderid, $uid, $new->{$uid}{'flags'}, \@labels, $new->{$uid}{envelope}, str2time($new->{$uid}{internaldate}), $msgid, $thrid, $new->{$uid}{'rfc822.size'});
    }
  }

  $Self->dupdate('ifolders', {highestmodseq => $res->{newstate}{highestmodseq}, uidfirst => $uidfirst, uidnext => $res->{newstate}{uidnext}}, {ifolderid => $ifolderid});

  $Self->commit();

  return $didold if $batchsize;

  # need to make changes before counting
  $Self->begin();
  my ($count) = $Self->dbh->selectrow_array("SELECT COUNT(*) FROM imessages WHERE ifolderid = ?", {}, $ifolderid);
  $Self->commit();
  # if we don't know everything, we have to ALWAYS check or moves break
  if ($uidfirst != 1 or $count != $res->{newstate}{exists}) {
    # welcome to the future
    $uidnext = $res->{newstate}{uidnext};
    my $to = $uidnext - 1;
    $Self->log('debug', "COUNTING $imapname: $uidfirst:$to (something deleted)");
    my $res = $Self->backend_cmd('imap_count', $imapname, $uidvalidity, "$uidfirst:$to");
    $Self->begin();
    my $uids = $res->{data};
    my $data = $Self->dbh->selectcol_arrayref("SELECT uid FROM imessages WHERE ifolderid = ? AND uid >= ? AND uid <= ?", {}, $ifolderid, $uidfirst, $to);
    my %exists = map { $_ => 1 } @$uids;
    foreach my $uid (@$data) {
      next if $exists{$uid};
      $Self->deleted_record($ifolderid, $uid);
    }
    $Self->commit();
  }
}

sub imap_search {
  my $Self = shift;
  my @search = @_;

  if ($Self->{is_gmail}) {
    if ($search[0] eq 'text') {
      @search = ('x-gm-raw', $search[1]);
    }
    if ($search[0] eq 'from') {
      @search = ('x-gm-raw', "from:$search[1]");
    }
    if ($search[0] eq 'to') {
      @search = ('x-gm-raw', "to:$search[1]");
    }
    if ($search[0] eq 'cc') {
      @search = ('x-gm-raw', "cc:$search[1]");
    }
    if ($search[0] eq 'subject') {
      @search = ('x-gm-raw', "subject:$search[1]");
    }
    if ($search[0] eq 'body') {
      @search = ('x-gm-raw', $search[1]);
    }
  }

  $Self->begin();
  my $data = $Self->dget('ifolders');
  if ($Self->{is_gmail}) {
    $data = [ grep { lc $_->{label} eq '\\allmail' or lc $_->{label} eq '\\trash' } @$data ];
  }
  $Self->commit();

  my %matches;
  foreach my $item (@$data) {
    my $from = $item->{uidfirst};
    my $to = $item->{uidnext}-1;
    my $res = $Self->backend_cmd('imap_search', $item->{imapname}, 'uid', "$from:$to", @search);
    # XXX - uidvaldity changed
    next unless $res->[2] == $item->{uidvalidity};
    $Self->begin();
    foreach my $uid (@{$res->[3]}) {
      my ($msgid) = $Self->dbh->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? and uid = ?", {}, $item->{ifolderid}, $uid);
      $matches{$msgid} = 1;
    }
    $Self->commit();
  }

  return \%matches;
}

sub mark_sync {
  my $Self = shift;
  my ($msgid) = @_;
  $Self->dbh->do("INSERT OR IGNORE INTO imsgidtodo (msgid) VALUES (?)", {}, $msgid);
}

sub changed_record {
  my $Self = shift;
  my ($folder, $uid, $flaglist, $labellist) = @_;

  my $flags = $json->encode([grep { lc $_ ne '\\recent' } sort @$flaglist]);
  my $labels = $json->encode([sort @$labellist]);

  return unless $Self->dmaybeupdate('imessages', {flags => $flags, labels => $labels}, {ifolderid => $folder, uid => $uid});

  my ($msgid) = $Self->dbh->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $folder, $uid);

  $Self->mark_sync($msgid);
}

sub import_message {
  my $Self = shift;
  my $rfc822 = shift;
  my $mailboxIds = shift;
  my $keywords = shift;

  $Self->begin();
  my $folderdata = $Self->dget('ifolders');
  $Self->commit();

  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;

  # store to the first named folder - we can use labels on gmail to add to other folders later.
  my ($id, @others) = @$mailboxIds;
  my $imapname = $jmailmap{$id}{imapname};

  my %flags = %$keywords;
  my @flags;
  push @flags, "\\Answered" if delete $flags{'$Answered'};
  push @flags, "\\Flagged" if delete $flags{'$Flagged'};
  push @flags, "\\Draft" if delete $flags{'$Draft'};
  push @flags, "\\Seen" if delete $flags{'$Seen'};
  push @flags, sort keys %flags;

  my $internaldate = time(); # XXX - allow setting?
  my $date = Date::Format::time2str('%e-%b-%Y %T %z', $internaldate);

  my $data = $Self->backend_cmd('imap_append', $imapname, "(@flags)", $date, $rfc822);
  # XXX - compare $data->[2] with uidvalidity
  my $uid = $data->[3];

  # make sure we're up to date: XXX - imap only
  if ($Self->{is_gmail}) {
    my ($am) = grep { lc $_->{label} eq '\\allmail' } @$folderdata;
    $Self->do_folder($am->{ifolderid}, undef);
  }
  else {
    my $fdata = $jmailmap{$mailboxIds->[0]};
    $Self->do_folder($fdata->{ifolderid}, $fdata->{label});
  }

  $Self->begin();
  my ($msgid, $thrid, $size) = $Self->dbh->selectrow_array("SELECT msgid, thrid, size FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $jmailmap{$id}{ifolderid}, $uid);
  $Self->commit();

  # save us having to download it again - drop out of transaction so we don't wait on the parse
  my $eml = Email::MIME->new($rfc822);
  my $message = $Self->parse_message($msgid, $eml);

  $Self->begin();
  $Self->dinsert('jrawmessage', {
    msgid => $msgid,
    parsed => $json->encode($message),
    hasAttachment => $message->{hasAttachment},
  });
  $Self->commit();

  return ($msgid, $thrid, $size);
}

sub update_messages {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %notchanged;
  my %changed;

  my %map;
  foreach my $msgid (keys %$changes) {
    my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    if (@$data) {
      foreach my $row (@$data) {
        my ($ifolderid, $uid) = @$row;
        $map{$msgid}{$ifolderid}{$uid} = 1;
      }
    }
    else {
      $notchanged{$msgid} = {type => 'notFound', description => "No such message on server"};
    }
  }

  my $folderdata = $Self->dget('ifolders');
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;
  my $jmapdata = $Self->dget('jmailboxes');
  my %jidmap = map { $_->{jmailboxid} => ($_->{role} || '') } @$jmapdata;
  my %jrolemap = map { $_->{role} => $_->{jmailboxid} } grep { $_->{role} } @$jmapdata;

  $Self->commit();

  foreach my $msgid (keys %map) {
    my $action = $changes->{$msgid};
    eval {
			foreach my $ifolderid (sort keys %{$map{$msgid}}) {
				my @uids = sort keys %{$map{$msgid}{$ifolderid}};
				# XXX - merge similar actions?
				my $imapname = $foldermap{$ifolderid}{imapname};
				my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
				next unless ($imapname and $uidvalidity);
				if (exists $action->{keywords}) {
					my %flags = %{$action->{keywords}};
					my @flags;
					push @flags, "\\Answered" if delete $flags{'$Answered'};
					push @flags, "\\Flagged" if delete $flags{'$Flagged'};
					push @flags, "\\Draft" if delete $flags{'$Draft'};
					push @flags, "\\Seen" if delete $flags{'$Seen'};
					push @flags, sort keys %flags;
					$Self->log('debug', "STORING (@flags) for @uids");
					$Self->backend_cmd('imap_update', $imapname, $uidvalidity, \@uids, \@flags);
				}
			}
			if (exists $action->{mailboxIds}) {
				# jmailboxid
				my @mboxes = map { $idmap->($_) } keys %{$action->{mailboxIds}};

				# existing ifolderids containing this message
				# identify a source message to work from
				my ($ifolderid) = sort keys %{$map{$msgid}};
				my $imapname = $foldermap{$ifolderid}{imapname};
				my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
				my ($uid) = sort keys %{$map{$msgid}{$ifolderid}};

				if ($Self->{is_gmail}) {
					# because 'archive' is synthetic on gmail we strip it here
					(@mboxes) = grep { $jidmap{$_} ne 'archive' } @mboxes;
					my @labels = grep { $_ and lc $_ ne '\\allmail' } map { $jmailmap{$_}{label} } @mboxes;
					$Self->backend_cmd('imap_labels', $imapname, $uidvalidity, $uid, \@labels);
				}
				else {
					# existing ifolderids with this message
					my %current = map { $_ => 1 } keys %{$map{$msgid}};
					# new ifolderids that should contain this message
					my %new = map { $jmailmap{$_}{ifolderid} => 1 } @mboxes;

					# for all the new folders
					foreach my $ifolderid (sort keys %new) {
						# unless there's already a matching message in it
						next if delete $current{$ifolderid};
						# copy from the existing message
						my $newfolder = $foldermap{$ifolderid}{imapname};
						$Self->backend_cmd('imap_copy', $imapname, $uidvalidity, $uid, $newfolder);
					}
					foreach my $ifolderid (sort keys %current) {
						# these ifolderids didn't exist in %new, so delete all matching UIDs from these folders
						my $imapname = $foldermap{$ifolderid}{imapname};
						my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
						my @uids = sort keys %{$map{$msgid}{$ifolderid}};
						$Self->backend_cmd('imap_move', $imapname, $uidvalidity, \@uids);
					}
				}
			}
    };
    if ($@) {
      $notchanged{$msgid} = { type => 'error', description => $@ };
    }
    else {
      $changed{$msgid} = undef;
    }
  }

  return (\%changed, \%notchanged);
}

sub destroy_messages {
  my $Self = shift;
  my $ids = shift;

  return ([], {}) unless @$ids;

  $Self->begin();
  my %destroymap;
  my %notdestroyed;
  foreach my $msgid (@$ids) {
    my $data = $Self->dbh->selectall_arrayref("SELECT ifolderid, uid FROM imessages WHERE msgid = ?", {}, $msgid);
    if (@$data) {
      foreach my $row (@$data) {
        my ($ifolderid, $uid) = @$row;
        $destroymap{$ifolderid}{$uid} = $msgid;
      }
    }
    else {
      $notdestroyed{$msgid} = {type => 'notFound', description => "No such message on server"};
    }
  }

  my $folderdata = $Self->dget('ifolders');
  my %foldermap = map { $_->{ifolderid} => $_ } @$folderdata;
  my %jmailmap = map { $_->{jmailboxid} => $_ } grep { $_->{jmailboxid} } @$folderdata;

  $Self->commit();

  my @destroyed;
  foreach my $ifolderid (keys %destroymap) {
    # XXX - merge similar actions?
    my $imapname = $foldermap{$ifolderid}{imapname};
    my $uidvalidity = $foldermap{$ifolderid}{uidvalidity};
    unless ($imapname) {
      $notdestroyed{$_} = {type => 'notFound', description => "No folder"} for values %{$destroymap{$ifolderid}};
    }
    my $uids = [sort keys %{$destroymap{$ifolderid}}];
    $Self->backend_cmd('imap_move', $imapname, $uidvalidity, $uids, undef); # no destination folder
    push @destroyed, values %{$destroymap{$ifolderid}};
  }

  return (\@destroyed, \%notdestroyed);
}

sub deleted_record {
  my $Self = shift;
  my ($ifolderid, $uid) = @_;

  my ($msgid) = $Self->dbh->selectrow_array("SELECT msgid FROM imessages WHERE ifolderid = ? AND uid = ?", {}, $ifolderid, $uid);
  return unless $msgid;

  $Self->ddelete('imessages', {ifolderid => $ifolderid, uid => $uid});

  $Self->mark_sync($msgid);
}

sub new_record {
  my $Self = shift;
  my ($ifolderid, $uid, $flaglist, $labellist, $envelope, $internaldate, $msgid, $thrid, $size) = @_;

  my $flags = $json->encode([grep { lc $_ ne '\\recent' } sort @$flaglist]);
  my $labels = $json->encode([sort @$labellist]);

  my $data = {
    ifolderid => $ifolderid,
    uid => $uid,
    flags => $flags,
    labels => $labels,
    internaldate => $internaldate,
    msgid => $msgid,
    thrid => $thrid,
    envelope => $json->encode($envelope),
    size => $size,
  };

  # delete first to correctly handle msgid changes (shouldn't be possible, but whatever)
  $Self->deleted_record($ifolderid, $uid);
  $Self->dinsert('imessages', $data);

  $Self->mark_sync($msgid);
}

sub sync_jmap_msgid {
  my $Self = shift;
  my ($msgid) = @_;

  my $imessages = $Self->dbh->selectall_arrayref("SELECT flags, labels FROM imessages WHERE msgid = ?", {}, $msgid);

  my %labels;
  my %flags;
  foreach my $row (@$imessages) {
    my ($flags, $labels) = @$row;
    my $flaglist = decode_json($flags);
    my $labellist = decode_json($labels);
    $flags{$_} = 1 for @$flaglist;
    $labels{$_} = 1 for @$labellist;
  }

  my %flagdata;
  foreach my $flag (keys %flags) {
    if (lc $flag eq '\\seen') {
      $flagdata{'$Seen'} = $JSON::true;
    }
    elsif (lc $flag eq '\\flagged') {
      $flagdata{'$Flagged'} = $JSON::true;
    }
    elsif (lc $flag eq '\\draft') {
      $flagdata{'$Draft'} = $JSON::true;
    }
    elsif (lc $flag eq '\\answered') {
      $flagdata{'$Answered'} = $JSON::true;
    }
    else {
      $flagdata{$flag} = $JSON::true;
    }
  }

  my @list = keys %labels;

  # gmail empty list means archive at our end
  my $labels = $Self->labels();
  my @jmailboxids = grep { $_ } map { $labels->{$_}[1] } @list;

  # check for archive folder for gmail
  if ($Self->{is_gmail} and @$imessages and not @list) {
    @jmailboxids = $Self->dbh->selectrow_array("SELECT jmailboxid FROM jmailboxes WHERE role = 'archive'");
  }

  return $Self->delete_message($msgid) if (not @jmailboxids);

  my ($old) = $Self->dbh->selectrow_array("SELECT msgid FROM jmessages WHERE msgid = ? AND active = 1", {}, $msgid);

  $Self->log('debug', "DATA (@jmailboxids) for $msgid");

  if ($old) {
    $Self->log('debug', "changing $msgid");
    return $Self->change_message($msgid, {keywords => \%flagdata}, \@jmailboxids);
  }
  else {
    $Self->log('debug', "adding $msgid");
    my $data = $Self->dbh->selectrow_hashref("SELECT thrid,internaldate,size,envelope FROM imessages WHERE msgid = ?", {}, $msgid);
    return $Self->add_message({
      msgid => $msgid,
      internaldate => $data->{internaldate},
      thrid => $data->{thrid},
      msgsize => $data->{size},
      keywords => \%flagdata,
      isDraft => $flagdata{'$Draft'} ? 1 : 0,
      isUnread => $flagdata{'$Seen'} ? 0 : 1,
      _envelopedata($data->{envelope}),
    }, \@jmailboxids);
  }
}

sub sync_jmap {
  my $Self = shift;
  $Self->begin();
  my $msgids = $Self->dbh->selectcol_arrayref("SELECT msgid FROM imsgidtodo");
  foreach my $msgid (@$msgids) {
    $Self->sync_jmap_msgid($msgid);
    $Self->dbh->do("DELETE FROM imsgidtodo WHERE msgid = ?", {}, $msgid);
  }
  $Self->commit();
}

sub _normalsubject {
  my $sub = shift;
  return unless defined $sub;

  # Re: and friends
  $sub =~ s/^[ \t]*[A-Za-z0-9]+://g;
  # [LISTNAME] and friends
  $sub =~ s/^[ \t]*\\[[^]]+\\]//g;
  # Australian security services and frenemies
  $sub =~ s/[\\[(SEC|DLM)=[^]]+\\][ \t]*$//g;
  # any old whitespace
  $sub =~ s/[ \t\r\n]+//g;

  return $sub;
}

sub _envelopedata {
  my $data = shift;
  my $envelope = decode_json($data || "{}");
  my $encsub = eval { Encode::decode('MIME-Header', $envelope->{Subject}) };
  $encsub = $envelope->{Subject} unless defined $encsub;
  my $sortsub = _normalsubject($encsub);
  return (
    msgsubject => $encsub,
    sortsubject => $sortsub,
    msgfrom => $envelope->{From},
    msgto => $envelope->{To},
    msgcc => $envelope->{Cc},
    msgbcc => $envelope->{Bcc},
    msgdate => str2time($envelope->{Date}),
    msginreplyto => _trimh($envelope->{'In-Reply-To'}),
    msgmessageid => _trimh($envelope->{'Message-ID'}),
  );
}

sub fill_messages {
  my $Self = shift;
  my @ids = @_;

  return {} unless @ids;

  $Self->begin();

  my $data = $Self->dbh->selectall_arrayref("SELECT msgid, parsed FROM jrawmessage WHERE msgid IN (" . join(', ', map { "?" } @ids) . ")", {}, @ids);
  my %result;
  foreach my $line (@$data) {
    $result{$line->[0]} = decode_json($line->[1]);
  }
  my @need = grep { not $result{$_} } @ids;

  my %udata;
  if (@need) {
    my $uids = $Self->dbh->selectall_arrayref("SELECT ifolderid, uid, msgid FROM imessages WHERE msgid IN (" . join(', ', map { "?" } @need) . ")", {}, @need);
    foreach my $row (@$uids) {
      my ($ifolderid, $uid, $msgno) = @$row;
      $udata{$ifolderid}{$uid} = $msgno;
    }
  }

  my %foldermap;
  foreach my $ifolderid (sort keys %udata) {
    my $uhash = $udata{$ifolderid};
    my $uids = join(',', sort { $a <=> $b } grep { not $result{$uhash->{$_}} } keys %$uhash);
    next unless $uids;
    my ($imapname, $uidvalidity) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity FROM ifolders WHERE ifolderid = ?", {}, $ifolderid);
    next unless $imapname;
    $foldermap{$ifolderid} = [$imapname, $uidvalidity];
  }

  # drop out of transaction to actually fetch the data
  $Self->commit();

  return \%result unless keys %udata;

  my %parsed;
  foreach my $ifolderid (sort keys %udata) {
    my $uhash = $udata{$ifolderid};
    my $uids = join(',', sort { $a <=> $b } grep { not $result{$uhash->{$_}} } keys %$uhash);
    next unless $uids;

    my $data = $foldermap{$ifolderid};
    next unless $data;

    my ($imapname, $uidvalidity) = @$data;
    my $res = $Self->backend_cmd('imap_fill', $imapname, $uidvalidity, $uids);
    foreach my $uid (keys %{$res->{data}}) {
      my $rfc822 = $res->{data}{$uid};
      next unless $rfc822;
      my $msgid = $uhash->{$uid};
      next if $result{$msgid};
      my $eml = Email::MIME->new($rfc822);
      $result{$msgid} = $parsed{$msgid} = $Self->parse_message($msgid, $eml);
    }
  }

  $Self->begin();
  foreach my $msgid (sort keys %parsed) {
    my $message = $parsed{$msgid};
    $Self->dinsert('jrawmessage', {
     msgid => $msgid,
     parsed => $json->encode($message),
     hasAttachment => $message->{hasAttachment},
    });
  }
  $Self->commit();

  # XXX - handle not getting data that we need?
  my @stillneed = grep { not $result{$_} } @ids;

  return \%result;
}

sub find_type {
  my $message = shift;
  my $part = shift;

  return $message->{type} if ($message->{id} || '') eq $part;

  foreach my $sub (@{$message->{attachments}}) {
    my $type = find_type($sub, $part);
    return $type if $type;
  }
}

sub get_raw_message {
  my $Self = shift;
  my $msgid = shift;
  my $part = shift;

  $Self->begin();
  my ($imapname, $uidvalidity, $uid) = $Self->dbh->selectrow_array("SELECT imapname, uidvalidity, uid FROM ifolders JOIN imessages USING (ifolderid) WHERE msgid = ?", {}, $msgid);
  $Self->commit();
  return unless $imapname;

  my $type = 'message/rfc822';
  if ($part) {
    my $parsed = $Self->fill_messages($msgid);
    $type = find_type($parsed->{$msgid}, $part);
  }

  my $res = $Self->backend_cmd('imap_getpart', $imapname, $uidvalidity, $uid, $part);

  return ($type, $res->{data});
}

sub create_mailboxes {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  # XXX - handle sort order issues - it may actually be necessary to create a folder to get its ID
  # so we know the ID of the next one, and so on.

  $Self->begin();
  my %todo;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $mailbox = $new->{$cid};

    unless (exists $mailbox->{name} and $mailbox->{name} ne '') {
      $notcreated{$cid} = {type => 'invalidProperties', description => "name is required"};
      next;
    }

    my $encname = eval { encode('IMAP-UTF-7', $mailbox->{name}) };
    unless (defined $encname) {
      $notcreated{$cid} = {type => 'invalidProperties', description => "name can't be used with IMAP proxy"};
      next;
    }

    if ($mailbox->{parentId}) {
      my ($parentName, $sep) = $Self->dbh->selectrow_array("SELECT imapname, sep FROM ifolders WHERE jmailboxid = ?", {}, $mailbox->{parentId});
      # XXX - check "mailCreateChild" on parent mailbox
      unless ($parentName) {
        $notcreated{$cid} = {type => 'notFound', description => "parent folder not found"};
        next;
      }
      $todo{$cid} = [$parentName . $sep . $encname, $sep];
    }
    else {
      # will probably get INBOX - but meh, close enough.  Sync will fix it if needed.  Better
      # would be to use namespace to lift it when we lift the prefix
      my ($sep) = $Self->dbh->selectrow_array("SELECT sep FROM ifolders ORDER BY ifolderid");
      my ($prefix) = $Self->dbh->selectrow_array("SELECT imapPrefix FROM iserver");
      $prefix = '' unless defined $prefix;
      $todo{$cid} = [$prefix . $encname, $sep];
    }
  }

  $Self->commit();

  my %createmap;
  foreach my $cid (sort { $todo{$a} cmp $todo{$b} } keys %todo) {
    my ($imapname, $sep) = @{$todo{$cid}};
    # XXX - check if already exists?
    my $res = $Self->backend_cmd('create_mailbox', $imapname);
    if ($res->[1] eq 'ok') {
      my $mailbox = $new->{$cid};
      # yeah, I don't care so much here about the cost of lots of transactions, creating a mailbox is expensive
      $Self->begin();
      my $jmailboxid = new_uuid_string();
      my $ifolderid = $Self->dinsert('ifolders', {sep => $sep, imapname => $imapname, label => $mailbox->{name}, jmailboxid => $jmailboxid});
      $Self->dmake('jmailboxes', {name => $mailbox->{name}, jmailboxid => $jmailboxid, sortOrder => $mailbox->{sortOrder} || 4, parentId => $mailbox->{parentId}});

      $Self->commit();

      $createmap{$cid} = { id => $jmailboxid };
    }
    else {
      $notcreated{$cid} = {type => 'internalError', description => $res->[2]};
    }
  } 

  return (\%createmap, \%notcreated);
}

sub update_mailboxes {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  return ({}, {}) unless %$update;

  $Self->begin();

  my %changed;
  my %notchanged;
  my %namemap;
  # XXX - reorder the crap out of this if renaming multiple mailboxes due to deep rename
  foreach my $jid (keys %$update) {
    my $mailbox = $update->{$jid};
    unless (keys %$mailbox) {
      $notchanged{$jid} = {type => 'invalidProperties', description => "nothing to change"};
      next;
    }

    my $data = $Self->dgetone('jmailboxes', {jmailboxid => $jid});
    foreach my $key (keys %$mailbox) { # XXX - check if valid
      $data->{$key} = $update->{$key};
    }
    my $parentId = $data->{parentId};
    if ($data->{parentId}) {
      $parentId = $idmap->($data->{parentId});
    }

    my $encname = eval { encode('IMAP-UTF-7', $data->{name}) };
    unless (defined $encname) {
      $notchanged{$jid} = {type => 'invalidProperties', description => "name can't be used with IMAP proxy"};
      next;
    }

    my ($oldname,$ifolderid) = $Self->dbh->selectrow_array("SELECT imapname,ifolderid FROM ifolders WHERE jmailboxid = ?", {}, $jid);

    if ($parentId) {
      my ($parentName, $sep) = $Self->dbh->selectrow_array("SELECT imapname, sep FROM ifolders WHERE jmailboxid = ?", {}, $parentId);
      unless ($parentName) {
        $notchanged{$jid} = {type => 'invalidProperties', description => "parent folder not found"};
        next;
      }
      $namemap{$oldname} = [$parentName . $sep . $encname, $jid, $ifolderid];
    }
    else {
      my ($prefix) = $Self->dbh->selectrow_array("SELECT imapPrefix FROM iserver");
      $prefix = '' unless $prefix;
      $namemap{$oldname} = [$prefix . $encname, $jid, $ifolderid];
    }
  }

  $Self->commit();

  my %toupdate;
  foreach my $oldname (sort keys %namemap) {
    my ($imapname, $jid, $ifolderid) = @{$namemap{$oldname}};

    if ($imapname eq $oldname) {
      # no change, yay
      $changed{$jid} = undef;
      next;
    }

    my $res = $Self->backend_cmd('rename_mailbox', $oldname, $imapname);
    if ($res->[1] eq 'ok') {
      $changed{$jid} = undef;
      $toupdate{$jid} = [$imapname, $ifolderid];
    }
    else {
      $notchanged{$jid} = {type => 'serverError', description => $res->[2]};
    }
  }

  if (keys %toupdate) {
    $Self->begin();
    foreach my $jid (keys %toupdate) {
      my ($imapname, $ifolderid) = @{$toupdate{$jid}};
      my $change = $update->{$jid};
      $Self->dmaybeupdate('ifolders', {imapname => $imapname}, {ifolderid => $ifolderid});
      my %changes;
      $changes{name} = $change->{name} if exists $change->{name};
      $changes{parentId} = $change->{parentId} if exists $change->{parentId};
      $changes{sortOrder} = $change->{sortOrder} if exists $change->{sortOrder};
      $Self->dmaybedirty('jmailboxes', \%changes, {jmailboxid => $jid});
    }
    $Self->commit();
  }

  return (\%changed, \%notchanged);
}

sub destroy_mailboxes {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my @destroyed;
  my %notdestroyed;
  my %namemap;
  foreach my $jid (@$destroy) {
    my ($oldname, $ifolderid) = $Self->dbh->selectrow_array("SELECT imapname,ifolderid FROM ifolders WHERE jmailboxid = ?", {}, $jid);
    if ($oldname) {
      $namemap{$oldname} = [$jid, $ifolderid];
    }
    else {
      $notdestroyed{$jid} = {type => 'invalidProperties', description => "parent folder not found"};
    }
  }

  $Self->commit();

  # we reverse so we delete children before parents
  my %toremove;
  foreach my $oldname (reverse sort keys %namemap) {
    my ($jid, $ifolderid) = @{$namemap{$oldname}};
    my $res = $Self->backend_cmd('delete_mailbox', $oldname);
    if ($res->[1] eq 'ok') {
      push @destroyed, $jid;
      $toremove{$jid} = $ifolderid;
    }
    else {
      $notdestroyed{$jid} = {type => 'serverError', description => $res->[2]};
    }
  }

  if (keys %toremove) {
    $Self->begin();
    foreach my $jid (sort keys %toremove) {
      my $ifolderid = $toremove{$jid};
      $Self->ddelete('ifolders', {ifolderid => $ifolderid});
      $Self->dupdate('jmailboxes', {active => 0}, {jmailboxid => $jid});
    }
    $Self->commit();
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_calendar_events {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %todo;
  my %createmap;
  my %notcreated;
  foreach my $cid (sort keys %$new) {
    my $calendar = $new->{$cid};
    my ($href) = $Self->dbh->selectrow_array("SELECT href FROM icalendars WHERE icalendarid = ?", {}, $calendar->{calendarId});
    unless ($href) {
      $notcreated{$cid} = {type => 'notFound', description => "No such calendar on server"};
      next;
    }
    my $uid = new_uuid_string();

    $todo{$cid} = [$href, {%$calendar, uid => $uid}];

    $createmap{$cid} = { id => $uid };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    $Self->backend_cmd('new_event', @{$todo{$cid}});
  }

  return (\%createmap, \%notcreated);
}

sub update_calendar_events {
  my $Self = shift;
  my $update = shift;
  my $idmap = shift;

  return ({}, {}) unless %$update;

  $Self->begin();

  my %todo;
  my %changed;
  my %notchanged;
  foreach my $uid (keys %$update) {
    my $calendar = $update->{$uid};
    my ($resource) = $Self->dbh->selectrow_array("SELECT resource FROM ievents WHERE uid = ?", {}, $uid);
    unless ($resource) {
      $notchanged{$uid} = {type => 'notFound', description => "No such event on server"};
      next;
    }

    $todo{$resource} = $calendar;

    $changed{$uid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('update_event', $href, $todo{$href});
  }

  return (\%changed, \%notchanged);
}

sub destroy_calendar_events {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my %todo;
  my @destroyed;
  my %notdestroyed;
  foreach my $uid (@$destroy) {
    my ($resource) = $Self->dbh->selectrow_array("SELECT resource FROM ievents WHERE uid = ?", {}, $uid);
    unless ($resource) {
      $notdestroyed{$uid} = {type => 'notFound', description => "No such event on server"};
      next;
    }

    $todo{$resource} = 1;

    push @destroyed, $uid;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('delete_event', $href);
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contact_groups {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %todo;
  my %createmap;
  my %notcreated;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    #my ($href) = $Self->dbh->selectrow_array("SELECT href FROM iaddressbooks WHERE iaddressbookid = ?", {}, $contact->{addressbookId});
    my ($href) = $Self->dbh->selectrow_array("SELECT href FROM iaddressbooks");
    unless ($href) {
      $notcreated{$cid} = {type => 'notFound', description => "No such addressbook on server"};
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new();
    my $uid = new_uuid_string();
    $card->uid($uid);
    $card->VKind('group');
    $card->VFN($contact->{name}) if exists $contact->{name};
    if (exists $contact->{contactIds}) {
      my @ids = @{$contact->{contactIds}};
      $card->VGroupContactUIDs(\@ids);
    }

    $todo{$cid} = [$href, $card];

    $createmap{$cid} = { id => $uid };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    $Self->backend_cmd('new_card', @{$todo{$cid}});
  }

  return (\%createmap, \%notcreated);
}

sub update_contact_groups {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %todo;
  my %changed;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my ($resource, $content) = $Self->dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notchanged{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new_fromstring($content);
    $card->VKind('group');
    $card->VFN($contact->{name}) if exists $contact->{name};
    if (exists $contact->{contactIds}) {
      my @ids = map { $idmap->($_) } @{$contact->{contactIds}};
      $card->VGroupContactUIDs(\@ids);
    }

    $todo{$resource} = $card;
    $changed{$carduid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('update_card', $href, $todo{$href});
  }

  return (\%changed, \%notchanged);
}

sub destroy_contact_groups {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my %todo;
  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    my ($resource, $content) = $Self->dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notdestroyed{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    $todo{$resource} = 1;
    push @destroyed, $carduid;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('delete_card', $href);
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_contacts {
  my $Self = shift;
  my $new = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %createmap;
  my %notcreated;
  my %todo;
  foreach my $cid (keys %$new) {
    my $contact = $new->{$cid};
    my ($href) = $Self->dbh->selectrow_array("SELECT href FROM iaddressbooks");
    unless ($href) {
      $notcreated{$cid} = {type => 'notFound', description => "No such addressbook on server"};
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new();
    my $uid = new_uuid_string();
    $card->uid($uid);
    $card->VLastName($contact->{lastName}) if exists $contact->{lastName};
    $card->VFirstName($contact->{firstName}) if exists $contact->{firstName};
    $card->VTitle($contact->{prefix}) if exists $contact->{prefix};

    $card->VCompany($contact->{company}) if exists $contact->{company};
    $card->VDepartment($contact->{department}) if exists $contact->{department};

    $card->VEmails(@{$contact->{emails}}) if exists $contact->{emails};
    $card->VAddresses(@{$contact->{addresses}}) if exists $contact->{addresses};
    $card->VPhones(@{$contact->{phones}}) if exists $contact->{phones};
    $card->VOnline(@{$contact->{online}}) if exists $contact->{online};

    $card->VNickname($contact->{nickname}) if exists $contact->{nickname};
    $card->VBirthday($contact->{birthday}) if exists $contact->{birthday};
    $card->VNotes($contact->{notes}) if exists $contact->{notes};

    $todo{$cid} = [$href, $card];

    $createmap{$cid} = { id => $uid };
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    $Self->backend_cmd('new_card', @{$todo{$cid}});
  }

  return (\%createmap, \%notcreated);
}

sub update_contacts {
  my $Self = shift;
  my $changes = shift;
  my $idmap = shift;

  return ({}, {}) unless %$changes;

  $Self->begin();

  my %todo;
  my %changed;
  my %notchanged;
  foreach my $carduid (keys %$changes) {
    my $contact = $changes->{$carduid};
    my ($resource, $content) = $Self->dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notchanged{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    my ($card) = Net::CardDAVTalk::VCard->new_fromstring($content);
    $card->VLastName($contact->{lastName}) if exists $contact->{lastName};
    $card->VFirstName($contact->{firstName}) if exists $contact->{firstName};
    $card->VTitle($contact->{prefix}) if exists $contact->{prefix};

    $card->VCompany($contact->{company}) if exists $contact->{company};
    $card->VDepartment($contact->{department}) if exists $contact->{department};

    $card->VEmails(@{$contact->{emails}}) if exists $contact->{emails};
    $card->VAddresses(@{$contact->{addresses}}) if exists $contact->{addresses};
    $card->VPhones(@{$contact->{phones}}) if exists $contact->{phones};
    $card->VOnline(@{$contact->{online}}) if exists $contact->{online};

    $card->VNickname($contact->{nickname}) if exists $contact->{nickname};
    $card->VBirthday($contact->{birthday}) if exists $contact->{birthday};
    $card->VNotes($contact->{notes}) if exists $contact->{notes};

    $todo{$resource} = $card;
    $changed{$carduid} = undef;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('update_card', $href, $todo{$href});
  }

  return (\%changed, \%notchanged);
}

sub destroy_contacts {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my %todo;
  my @destroyed;
  my %notdestroyed;
  foreach my $carduid (@$destroy) {
    my ($resource, $content) = $Self->dbh->selectrow_array("SELECT resource, content FROM icards WHERE uid = ?", {}, $carduid);
    unless ($resource) {
      $notdestroyed{$carduid} = {type => 'notFound', description => "No such card on server"};
      next;
    }
    $todo{$resource} = 1;
    push @destroyed, $carduid;
  }

  $Self->commit();

  foreach my $href (sort keys %todo) {
    $Self->backend_cmd('delete_card', $href);
  }

  return (\@destroyed, \%notdestroyed);
}

sub create_submissions {
  my $Self = shift;
  my $new = shift;
  my $idmap = shift;

  return ({}, {}) unless keys %$new;

  $Self->begin();

  my %todo;
  my %createmap;
  my %notcreated;
  foreach my $cid (sort keys %$new) {
    my $sub = $new->{$cid};

    my $msgid = $idmap->($sub->{messageId});

    unless ($msgid) {
      $notcreated{$cid} = { error => "no msgid provided" };
      next;
    }

    my ($thrid) = $Self->dbh->selectrow_array("SELECT thrid from jmessages WHERE active = 1 and msgid = ?", {}, $msgid);
    unless ($thrid) {
      $notcreated{$cid} = { error => "message does not exist" };
      next;
    }

    my $id = $Self->dmake('jsubmission', {
      sendat => $sub->{sendAt} ? str2time($sub->{sendAt}) : time(),
      msgid => $msgid,
      thrid => $thrid,
      envelope => $sub->{envelope} ? $json->encode($sub->{envelope}) : undef,
    });

    $createmap{$cid} = { id => $id };
    $todo{$cid} = $msgid;
  }

  $Self->commit();

  foreach my $cid (sort keys %todo) {
    my $sub = $new->{$cid};
    # XXX - on error?  Should remove $createmap{$cid} and set $notcreated{$cid}
    my ($type, $rfc822) = $Self->get_raw_message($todo{$cid});
    # XXX - does this die on error?
    $Self->backend_cmd('send_email', $rfc822, $sub->{envelope});
  }

  return (\%createmap, \%notcreated);
}

sub update_submissions {
  my $Self = shift;
  my $changed = shift;
  my $idmap = shift;

  return ({}, { map { $_ => "change not supported" } keys %$changed });
}

sub destroy_submissions {
  my $Self = shift;
  my $destroy = shift;

  return ([], {}) unless @$destroy;

  $Self->begin();

  my @destroyed;
  my %notdestroyed;
  my %namemap;
  foreach my $subid (@$destroy) {
    my ($active) = $Self->dbh->selectrow_array("SELECT active FROM jsubmission WHERE subid = ?", {}, $subid);
    if ($active) {
      push @destroyed, $subid;
      $Self->ddelete('jsubmission', {subid => $subid});
    }
    else {
      $notdestroyed{$subid} = {type => 'notFound', description => "submission not found"};
    }
  }

  $Self->commit();

  return (\@destroyed, \%notdestroyed);
}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  $Self->SUPER::_initdb($dbh);

  # XXX - password encryption?
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iserver (
  username TEXT PRIMARY KEY,
  password TEXT,
  imapHost TEXT,
  imapPort INTEGER,
  imapSSL INTEGER,
  imapPrefix TEXT,
  smtpHost TEXT,
  smtpPort INTEGER,
  smtpSSL INTEGER,
  caldavURL TEXT,
  carddavURL TEXT,
  lastfoldersync DATE,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ifolders (
  ifolderid INTEGER PRIMARY KEY NOT NULL,
  jmailboxid INTEGER,
  sep TEXT NOT NULL,
  imapname TEXT NOT NULL,
  label TEXT,
  uidvalidity INTEGER,
  uidfirst INTEGER,
  uidnext INTEGER,
  highestmodseq INTEGER,
  uniqueid TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ifolderj ON ifolders (jmailboxid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS ifolderlabel ON ifolders (label)");


  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS imessages (
  imessageid INTEGER PRIMARY KEY NOT NULL,
  ifolderid INTEGER,
  uid INTEGER,
  internaldate DATE,
  modseq INTEGER,
  flags TEXT,
  labels TEXT,
  thrid TEXT,
  msgid TEXT,
  envelope TEXT,
  bodystructure TEXT,
  size INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE UNIQUE INDEX IF NOT EXISTS imsgfrom ON imessages (ifolderid, uid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS imessageid ON imessages (msgid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS imessagethrid ON imessages (thrid)");

# not used for Gmail, but it doesn't hurt to have it
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ithread (
  messageid TEXT PRIMARY KEY,
  sortsubject TEXT,
  thrid TEXT
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ithrid ON ithread (thrid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icalendars (
  icalendarid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  sortOrder INTEGER,
  color TEXT,
  syncToken TEXT,
  jcalendarid INTEGER,
  mtime DATE NOT NULL
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS ievents (
  ieventid INTEGER PRIMARY KEY NOT NULL,
  icalendarid INTEGER,
  resource TEXT,
  uid TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS ieventcal ON ievents (icalendarid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS ieventuid ON ievents (uid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS iaddressbooks (
  iaddressbookid INTEGER PRIMARY KEY NOT NULL,
  href TEXT,
  name TEXT,
  isReadOnly INTEGER,
  sortOrder INTEGER,
  syncToken TEXT,
  jaddressbookid INTEGER,
  mtime DATE NOT NULL
);
EOF

# XXX - should we store 'kind' in this?  Means we know which j table to update
# if someone reuses a UID from a contact to a group or vice versa...
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS icards (
  icardid INTEGER PRIMARY KEY NOT NULL,
  iaddressbookid INTEGER,
  resource TEXT,
  uid TEXT,
  kind TEXT,
  content TEXT,
  mtime DATE NOT NULL
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS icardbook ON icards (iaddressbookid)");
  $dbh->do("CREATE INDEX IF NOT EXISTS icarduid ON icards (uid)");

  $dbh->do("CREATE TABLE IF NOT EXISTS imsgidtodo (msgid TEXT PRIMARY KEY NOT NULL)");

}

1;
