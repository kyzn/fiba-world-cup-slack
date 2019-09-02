use warnings;
use strict;

=head1 NAME

fiba-world-cup-slack 0.01

=cut

package FIBAWorldCupSlack;
our $VERSION = '0.01';

use File::Slurper qw/read_text write_text/;
use Furl;
use Getopt::Long;
use List::Util qw/any/;
use JSON::XS;

=head1 DESCRIPTION

FIBA World Cup game notifier in your Slack workspace.

Note that this only posts "game started" and "final score" notifications.

Run following command to install dependencies.

    cpanm File::Slurper Furl Getopt::Long List::Util JSON::XS

You can set a cronjob to run this script at every 5 minutes.

=head1 SYNOPSIS

First, you will need a Slack incoming webhook URL. Here's how to get it:

=over

=item Create an app at L<https://api.slack.com/apps?new_app=1>

=item Go to your app details page at L<https://api.slack.com>

=item Go to "Incoming webhooks" on left navigation, it will be there.

=back

Post from FIBA to screen

  perl fiba-world-cup-slack.pl

Post from FIBA to Slack

  perl fiba-world-cup-slack.pl --slack=https://hooks.slack.com/services/...

You can specify multiple Slack URLs

  perl fiba-world-cup-slack.pl --slack=... --slack=...

Post from local JSON file to screen

  perl fiba-world-cup-slack.pl --debug=downloaded.json

Post from local JSON file to Slack

  perl fiba-world-cup-slack.pl --debug=downloaded.json --slack=...

Add this to increase politeness sleep (defaults to 2 seconds)

  --sleep=10

=head1 LICENSE

MIT.

=head1 ATTRIBUTION

This script is based on
L<kyzn/fifa-world-cup-slack|https://github.com/kyzn/fifa-world-cup-slack>
which was partly based on
L<j0k3r/worldcup-slack-bot|https://github.com/j0k3r/worldcup-slack-bot>.

=cut

my @slack = ();
my $debug = '';
my $sleep = 2;
my $furl  = Furl->new;

GetOptions(
  'slack=s' => \@slack,
  'debug=s' => \$debug,
  'sleep=i' => \$sleep,
) or die 'Encountered an error when parsing arguments';

my $countries = {
  ANG => { flag => ':flag-ao:', name => 'Angola'        },
  ARG => { flag => ':flag-ar:', name => 'Argentina'     },
  AUS => { flag => ':flag-au:', name => 'Australia'     },
  BRA => { flag => ':flag-br:', name => 'Brazil'        },
  CAN => { flag => ':flag-ca:', name => 'Canada'        },
  CHN => { flag => ':flag-cn:', name => 'China'         },
  CIV => { flag => ':flag-ci:', name => 'Ivory Coast'   },
  CZE => { flag => ':flag-cz:', name => 'Czechia'       },
  DOM => { flag => ':flag-do:', name => 'Dominican Rep.'},
  ESP => { flag => ':flag-es:', name => 'Spain'         },
  FRA => { flag => ':flag-fr:', name => 'France'        },
  GER => { flag => ':flag-de:', name => 'Germany'       },
  GRE => { flag => ':flag-gr:', name => 'Greece'        },
  IRI => { flag => ':flag-ir:', name => 'Iran'          },
  ITA => { flag => ':flag-it:', name => 'Italy'         },
  JOR => { flag => ':flag-jo:', name => 'Jordan'        },
  JPN => { flag => ':flag-jp:', name => 'Japan'         },
  KOR => { flag => ':flag-kr:', name => 'South Korea'   },
  LTU => { flag => ':flag-lt:', name => 'Lithuania'     },
  MNE => { flag => ':flag-me:', name => 'Montenegro'    },
  NGR => { flag => ':flag-ni:', name => 'Nigeria'       },
  NZL => { flag => ':flag-nz:', name => 'New Zealand'   },
  PHI => { flag => ':flag-ph:', name => 'Philippines'   },
  POL => { flag => ':flag-pl:', name => 'Poland'        },
  PUR => { flag => ':flag-pr:', name => 'Puerto Rico'   },
  RUS => { flag => ':flag-ru:', name => 'Russia'        },
  SEN => { flag => ':flag-sn:', name => 'Senegal'       },
  SRB => { flag => ':flag-rs:', name => 'Serbia'        },
  TUN => { flag => ':flag-tn:', name => 'Tunisia'       },
  TUR => { flag => ':flag-tr:', name => 'Turkey'        },
  USA => { flag => ':flag-us:', name => 'United States' },
  VEN => { flag => ':flag-ve:', name => 'Venezuela'     }
};

my $status_lookup = {
  'Event-2-'   => { const => 'not_started', post => 0, score => 0, print => 'not started yet.' },
  'Event-4-'   => { const => 'started'    , post => 1, score => 0, print => 'game started.'    },
  'Event-7-'   => { const => 'finished'   , post => 0, score => 0, print => 'final score.'     },
  'Event-999-' => { const => 'over'       , post => 1, score => 1, print => 'final score.'     },
};

my ($games, $last_status);
# $games will keep details about games as follows:
#   $game_key => {
#     a => $team_code_a, a_score => $score_a,
#     b => $team_code_b, b_score => $score_b,
#     display_text => $text,
#     status       => $status,
#   }
# $last_status will store last status seen for a game.
#   $game_key => $last_status

# Read $games and $last_status from existing db.json
if (-e 'db.json'){
  my $db_json = read_text('db.json');
  my $db_hash = eval { decode_json($db_json) };
  die 'Could not decode existing db.json' unless $db_hash;
  $games       = $db_hash->{games}       // +{};
  $last_status = $db_hash->{last_status} // +{};
}

# Get game data (from FIBA or local json)
get_data();

# Main loop
while (my ($key,$game) = each %$games){
  my $game_status = $game->{status};

  # If this game was not seen before, just save it
  if (!$last_status->{$key}){
    $last_status->{$key} = $game_status;
  }
  # If game status has not changed, skip
  elsif ($last_status->{$key} eq $game_status){
    next;
  }
  # Otherwise, do the update
  else {
    # Update last state
    $last_status->{$key} = $game_status;
    my $status = $status_lookup->{$game_status};

    # Check if this is an event to be posted
    # Post never-seen-before statuses too
    if(!$status || $status->{post}){
      # Build text to be posted
      my $main =
        $countries->{$game->{a}}->{flag} . ' ' .
        $countries->{$game->{a}}->{name} . ' ' .
        ($status->{score} ? ($game->{a_score} // '') : '') . '-' .
        ($status->{score} ? ($game->{b_score} // '') : '') . ' ' .
        $countries->{$game->{b}}->{name} . ' ' .
        $countries->{$game->{b}}->{flag};
      my $desc = $game->{display_text} . ', ' .
        ($status ? $status->{print} : $game->{status});
      # Post
      post_data($main,$desc);
    }
  }
}

# Save db.json before finishing up
write_text('db.json',encode_json({games=>$games,last_status=>$last_status}));

# Helper subroutine to get data from FIBA or local file
sub get_data {
  my $content;
  if ($debug){
    $content = read_text($debug);
    die 'Error encountered when reading debug file' unless $content;
  } else {
    my $response = $furl->get('https://livecache.sportresult.com/node/db/FIBASTATS_PROD/9472_SCHEDULELS_JSON.json');
    die 'Error encountered when talking to FIBA' unless $response->is_success;
    $content = $response->content;
    # Uncomment to keep a local copy of json
    # write_text('downloaded.json',$content);
    sleep $sleep;
  }

  my $json = eval { decode_json($content) };
  die 'Error encountered when parsing content' unless $json;

  my $incoming_games = $json->{content}->{full}->{Games};
  my @game_keys      = keys %$incoming_games;

  foreach my $game_key (@game_keys){
    my $game = $incoming_games->{$game_key};
    $games->{$game_key} = {
      a => $game->{CompetitorA}->{TeamCode},
      b => $game->{CompetitorB}->{TeamCode},
      ($game->{CompetitorA}->{Score} ? (
        a_score => $game->{CompetitorA}->{Score},
        b_score => $game->{CompetitorB}->{Score},
      ) : ()),
      display_text => $game->{DisplayText},
      status       => $game->{Status},
    };
  }
}

# Helper subroutine to post to Slack or screen
sub post_data {
  my ($main, $desc) = @_;
  my $slack_text  = "*$main*";
  my $screen_text = "\n$main\n";
  if ($desc){
    $slack_text  .= "\n> $desc";
    $screen_text .= "$desc\n";
  }
  if (@slack){
    foreach my $url (@slack){
      $furl->post(
        $url,
        ["Content-type" => "application/json"],
        encode_json {"text" => $slack_text},
      );
      sleep $sleep;
    }
  } else {
    print '-' x 30;
    print $screen_text;
  }
}
