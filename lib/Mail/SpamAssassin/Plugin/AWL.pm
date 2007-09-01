# <@LICENSE>
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to you under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at:
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

=head1 NAME

Mail::SpamAssassin::Plugin::AWL - Normalize scores via auto-whitelist

=head1 SYNOPSIS

To try this out, add this or uncomment this line in init.pre:

  loadplugin     Mail::SpamAssassin::Plugin::AWL

Use the supplied 60_awl.cf file (ie you don't have to do anything) or
add these lines to a .cf file:

  header AWL             eval:check_from_in_auto_whitelist()
  describe AWL           From: address is in the auto white-list
  tflags AWL             userconf noautolearn
  priority AWL           1000

=head1 DESCRIPTION

This plugin module provides support for the auto-whitelist.  It keeps
track of the average SpamAssassin score for senders.  Senders are
tracked using a combination of their From: address and their IP address.
It then uses that average score to reduce the variability in scoring
from message to message and modifies the final score by pushing the
result towards the historical average.  This improves the accuracy of
filtering for most email.

=head1 TEMPLATE TAGS

This plugin module adds the following C<tags> that can be used as
placeholders in certain options.  See C<Mail::SpamAssassin::Conf>
for more information on TEMPLATE TAGS.

 _AWL_             AWL modifier
 _AWLMEAN_         Mean score on which AWL modification is based
 _AWLCOUNT_        Number of messages on which AWL modification is based
 _AWLPRESCORE_     Score before AWL

=cut

package Mail::SpamAssassin::Plugin::AWL;

use strict;
use warnings;
use bytes;
use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::AutoWhitelist;
use Mail::SpamAssassin::Logger;

use vars qw(@ISA);
@ISA = qw(Mail::SpamAssassin::Plugin);

# constructor: register the eval rule
sub new {
  my $class = shift;
  my $mailsaobject = shift;

  # some boilerplate...
  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsaobject);
  bless ($self, $class);

  # the important bit!
  $self->register_eval_rule("check_from_in_auto_whitelist");

  $self->set_config($mailsaobject->{conf});

  return $self;
}

sub set_config {
  my($self, $conf) = @_;
  my @cmds;

=head1 USER PREFERENCES

The following options can be used in both site-wide (C<local.cf>) and
user-specific (C<user_prefs>) configuration files to customize how
SpamAssassin handles incoming email messages.

=over 4

=item use_auto_whitelist ( 0 | 1 )		(default: 1)

Whether to use auto-whitelists.  Auto-whitelists track the long-term
average score for each sender and then shift the score of new messages
toward that long-term average.  This can increase or decrease the score
for messages, depending on the long-term behavior of the particular
correspondent.

For more information about the auto-whitelist system, please look
at the the C<Automatic Whitelist System> section of the README file.
The auto-whitelist is not intended as a general-purpose replacement
for static whitelist entries added to your config files.

Note that certain tests are ignored when determining the final
message score:

 - rules with tflags set to 'noautolearn'

=cut

  push (@cmds, {
		setting => 'use_auto_whitelist',
		default => 1,
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_BOOL
	       });

=item auto_whitelist_factor n	(default: 0.5, range [0..1])

How much towards the long-term mean for the sender to regress a message.
Basically, the algorithm is to track the long-term mean score of messages for
the sender (C<mean>), and then once we have otherwise fully calculated the
score for this message (C<score>), we calculate the final score for the
message as:

C<finalscore> = C<score> +  (C<mean> - C<score>) * C<factor>

So if C<factor> = 0.5, then we'll move to half way between the calculated
score and the mean.  If C<factor> = 0.3, then we'll move about 1/3 of the way
from the score toward the mean.  C<factor> = 1 means just use the long-term
mean; C<factor> = 0 mean just use the calculated score.

=cut

  push (@cmds, {
		setting => 'auto_whitelist_factor',
		default => 0.5,
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
	       });

=item user_awl_sql_override_username

Used by the SQLBasedAddrList storage implementation.

If this option is set the SQLBasedAddrList module will override the set
username with the value given.  This can be useful for implementing global
or group based auto-whitelist databases.

=cut

  push (@cmds, {
		setting => 'user_awl_sql_override_username',
		default => '',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=back

=head1 ADMINISTRATOR SETTINGS

These settings differ from the ones above, in that they are considered 'more
privileged' -- even more than the ones in the B<PRIVILEGED SETTINGS> section.
No matter what C<allow_user_rules> is set to, these can never be set from a
user's C<user_prefs> file.

=over 4

=item auto_whitelist_factory module (default: Mail::SpamAssassin::DBBasedAddrList)

Select alternative whitelist factory module.

=cut

  push (@cmds, {
		setting => 'auto_whitelist_factory',
		is_admin => 1,
		default => 'Mail::SpamAssassin::DBBasedAddrList',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=item auto_whitelist_path /path/filename (default: ~/.spamassassin/auto-whitelist)

This is the automatic-whitelist directory and filename.  By default, each user
has their own whitelist database in their C<~/.spamassassin> directory with
mode 0700.  For system-wide SpamAssassin use, you may want to share this
across all users, although that is not recommended.

=cut

  push (@cmds, {
		setting => 'auto_whitelist_path',
		is_admin => 1,
		default => '__userstate__/auto-whitelist',
		code => sub {
		  my ($self, $key, $value, $line) = @_;
		  unless (defined $value && $value !~ /^$/) {
		    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
		  }
		  if (-d $value) {
		    return $Mail::SpamAssassin::Conf::INVALID_VALUE;
		  }
		  $self->{auto_whitelist_path} = $value;
		}
	       });

=item auto_whitelist_db_modules Module ...	(default: see below)

What database modules should be used for the auto-whitelist storage database
file.   The first named module that can be loaded from the perl include path
will be used.  The format is:

  PreferredModuleName SecondBest ThirdBest ...

ie. a space-separated list of perl module names.  The default is:

  DB_File GDBM_File SDBM_File

NDBM_File is no longer supported, since it appears to have bugs that
preclude its use for the AWL (see SpamAssassin bug 4353).

=cut

  push (@cmds, {
		setting => 'auto_whitelist_db_modules',
		is_admin => 1,
		default => 'DB_File GDBM_File SDBM_File',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=item auto_whitelist_file_mode		(default: 0600)

The file mode bits used for the automatic-whitelist directory or file.

Make sure you specify this using the 'x' mode bits set, as it may also be used
to create directories.  However, if a file is created, the resulting file will
not have any execute bits set (the umask is set to 111).

=cut

  push (@cmds, {
		setting => 'auto_whitelist_file_mode',
		is_admin => 1,
		default => '0600',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
	       });

=item user_awl_dsn DBI:databasetype:databasename:hostname:port

Used by the SQLBasedAddrList storage implementation.

This will set the DSN used to connect.  Example:
C<DBI:mysql:spamassassin:localhost>

=cut

  push (@cmds, {
		setting => 'user_awl_dsn',
		is_admin => 1,
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=item user_awl_sql_username username

Used by the SQLBasedAddrList storage implementation.

The authorized username to connect to the above DSN.

=cut

  push (@cmds, {
		setting => 'user_awl_sql_username',
		is_admin => 1,
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=item user_awl_sql_password password

Used by the SQLBasedAddrList storage implementation.

The password for the database username, for the above DSN.

=cut

  push (@cmds, {
		setting => 'user_awl_sql_password',
		is_admin => 1,
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

=item user_awl_sql_table tablename

Used by the SQLBasedAddrList storage implementation.

The table user auto-whitelists are stored in, for the above DSN.

=cut

  push (@cmds, {
		setting => 'user_awl_sql_table',
		is_admin => 1,
		default => 'awl',
		type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	       });

  $conf->{parser}->register_commands(\@cmds);
}

sub check_from_in_auto_whitelist {
    my ($self, $pms) = @_;

    return 0 unless ($pms->{conf}->{use_auto_whitelist});

    my $timer = $self->{main}->time_method("check_awl");

    local $_ = lc $pms->get('From:addr');
    return 0 unless /\S/;

    # find the earliest usable "originating IP".  ignore private nets
    my $origip;
    foreach my $rly (reverse (@{$pms->{relays_trusted}}, @{$pms->{relays_untrusted}}))
    {
      next if ($rly->{ip_private});
      if ($rly->{ip}) {
	$origip = $rly->{ip}; last;
      }
    }

    my $scores = $pms->{conf}->{scores};
    my $tflags = $pms->{conf}->{tflags};
    my $points = 0;

    foreach my $test (@{$pms->{test_names_hit}}) {
      # ignore tests with 0 score in this scoreset,
      # or if the test is marked as "noautolearn"
      next if ($scores->{$test} == 0);
      next if (exists $tflags->{$test} && $tflags->{$test} =~ /\bnoautolearn\b/);

      $points += $scores->{$test};
    }

    my $awlpoints = (sprintf "%0.3f", $points) + 0;

   # Create the AWL object
    my $whitelist;
    eval {
      $whitelist = Mail::SpamAssassin::AutoWhitelist->new($pms->{main});

      # check
      my $meanscore = $whitelist->check_address($_, $origip);
      my $delta = 0;
    
      dbg("auto-whitelist: AWL active, pre-score: $pms->{score}, autolearn score: $awlpoints, ".
	  "mean: ". ($meanscore || 'undef') .", IP: ". ($origip || 'undef'));

      if (defined ($meanscore)) {
	$delta = ($meanscore - $awlpoints) * $pms->{main}->{conf}->{auto_whitelist_factor};
      
	$pms->set_tag('AWL', sprintf("%2.1f",$delta));
	$pms->set_tag('AWLMEAN', sprintf("%2.1f", $meanscore));
	$pms->set_tag('AWLCOUNT', sprintf("%2.1f", $whitelist->count()));
	$pms->set_tag('AWLPRESCORE', sprintf("%2.1f", $pms->{score}));
      }

      # Update the AWL *before* adding the new score, otherwise
      # early high-scoring messages are reinforced compared to
      # later ones.  http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=159704
      if (!$pms->{disable_auto_learning}) {
	$whitelist->add_score($awlpoints);
      }

      # current AWL score changes with each hit
      for my $set (0..3) {
	$pms->{conf}->{scoreset}->[$set]->{"AWL"} = sprintf("%0.3f", $delta);
      }

      if ($delta != 0) {
	$pms->got_hit("AWL", "AWL: ", ruletype => 'eval', score => $delta);
      }

      $whitelist->finish();
      1;
    } or do {
      my $eval_stat = $@ ne '' ? $@ : "errno=$!";  chomp $eval_stat;
      warn("auto-whitelist: open of auto-whitelist file failed: $eval_stat\n");
      # try an unlock, in case we got that far
      eval { $whitelist->finish(); } if $whitelist;
      return 0;
    };

    dbg("auto-whitelist: post auto-whitelist score: ".$pms->{score});

    # test hit is above
    return 0;
}

sub blacklist_address {
  my ($self, $args) = @_;

  return 0 unless ($self->{main}->{conf}->{use_auto_whitelist});

  unless ($args->{address}) {
    print "SpamAssassin auto-whitelist: failed to add address to blacklist\n";
    return;
  }
  
  my $whitelist;
  my $status;

  eval {
    $whitelist = Mail::SpamAssassin::AutoWhitelist->new($self->{main});

    if ($whitelist->add_known_bad_address($args->{address})) {
      print "SpamAssassin auto-whitelist: adding address to blacklist: " . $args->{address} . "\n";
      $status = 0;
    }
    else {
      print "SpamAssassin auto-whitelist: error adding address to blacklist\n";
      $status = 1;
    }
    $whitelist->finish();
    1;
  } or do {
    my $eval_stat = $@ ne '' ? $@ : "errno=$!";  chomp $eval_stat;
    warn("auto-whitelist: open of auto-whitelist file failed: $eval_stat\n");
    eval { $whitelist->finish(); };
    return 0;
  };

  return $status;
}

sub whitelist_address {
  my ($self, $args) = @_;

  return 0 unless ($self->{main}->{conf}->{use_auto_whitelist});

  unless ($args->{address}) {
    print "SpamAssassin auto-whitelist: failed to add address to whitelist\n";
    return 0;
  }

  my $whitelist;
  my $status;

  eval {
    $whitelist = Mail::SpamAssassin::AutoWhitelist->new($self->{main});

    if ($whitelist->add_known_good_address($args->{address})) {
      print "SpamAssassin auto-whitelist: adding address to whitelist: " . $args->{address} . "\n";
      $status = 1;
    }
    else {
      print "SpamAssassin auto-whitelist: error adding address to whitelist\n";
      $status = 0;
    }

    $whitelist->finish();
    1;
  } or do {
    my $eval_stat = $@ ne '' ? $@ : "errno=$!";  chomp $eval_stat;
    warn("auto-whitelist: open of auto-whitelist file failed: $eval_stat\n");
    eval { $whitelist->finish(); };
    return 0;
  };

  return $status;
}

sub remove_address {
  my ($self, $args) = @_;

  return 0 unless ($self->{main}->{conf}->{use_auto_whitelist});

  unless ($args->{address}) {
    print "SpamAssassin auto-whitelist: failed to remove address\n";
    return 0;
  }

  my $whitelist;
  my $status;

  eval {
    $whitelist = Mail::SpamAssassin::AutoWhitelist->new($self->{main});

    if ($whitelist->remove_address($args->{address})) {
      print "SpamAssassin auto-whitelist: removing address: " . $args->{address} . "\n";
      $status = 1;
    }
    else {
      print "SpamAssassin auto-whitelist: error removing address\n";
      $status = 0;
    }
  
    $whitelist->finish();
    1;
  } or do {
    my $eval_stat = $@ ne '' ? $@ : "errno=$!";  chomp $eval_stat;
    warn("auto-whitelist: open of auto-whitelist file failed: $eval_stat\n");
    eval { $whitelist->finish(); };
    return 0;
  };

  return $status;
}

1;

=back

=cut
