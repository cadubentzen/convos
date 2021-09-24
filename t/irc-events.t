#!perl
use lib '.';
use t::Helper;
use t::Server::Irc;
use Mojo::IOLoop;
use Convos::Core;

my $server     = t::Server::Irc->new->start;
my $core       = Convos::Core->new(backend => 'Convos::Core::Backend::File');
my $user       = $core->user({email => 'superman@example.com'});
my $connection = $user->connection({url => 'irc://localhost'});

$server->subtest(
  'welcome' => sub {
    $server->client($connection)->server_event_ok('_irc_event_nick')
      ->server_write_ok(['welcome.irc'])->client_event_ok('_irc_event_rpl_welcome')
      ->process_ok('welcome');

    $server->client_messages_ok([
      map { superhashof {ts => ignore, %$_} } {from => 'irc-localhost', type => 'notice'},
      {from => 'irc-localhost', type => 'notice'},
      {from => 'irc-localhost', type => 'notice'},
      {from => 'irc-localhost', type => 'notice'},
      {
        from    => 'hybrid8.debian.local',
        type    => 'private',
        message => 'Welcome to the debian Internet Relay Chat Network superman'
      },
    ]);
  }
);

$server->subtest(
  'error handlers' => sub {
    $server->server_write_ok(":localhost 404 superman #nopechan :Cannot send to channel\r\n")
      ->client_event_ok('_irc_event_err_cannotsendtochan')
      ->server_write_ok(":localhost 421 superman cool_cmd :Unknown command\r\n")
      ->client_event_ok('_irc_event_err_unknowncommand')
      ->server_write_ok(":localhost 432 superman nopeman :Erroneous nickname\r\n")
      ->client_event_ok('_irc_event_err_erroneusnickname')
      ->server_write_ok(":localhost 433 superman nopeman :Nickname is already in use\r\n")
      ->client_event_ok('_irc_event_err_nicknameinuse')
      ->server_write_ok(":localhost PING irc.example.com\r\n")->client_event_ok('_irc_event_ping')
      ->server_write_ok(":localhost PONG irc.example.com\r\n")->client_event_ok('_irc_event_pong')
      ->server_write_ok(":superwoman!Superduper\@localhost QUIT :Gone to lunch\r\n")
      ->client_event_ok('_irc_event_quit')->process_ok('error handlers');

    $server->client_messages_ok([
      map { superhashof {from => 'hybrid8.debian.local', type => 'error', ts => ignore, %$_} } (
        {message => 'Cannot send to channel #nopechan.'},
        {message => 'Unknown command: cool_cmd'},
        {message => 'Invalid nickname nopeman.'},
        {message => 'Nickname nopeman is already in use.'}
      ),
    ]);

    $server->client_states_ok(superbagof(
      [
        ignore,
        superhashof({
          authenticated => false,
          capabilities  => {},
          nick          => 'nopeman_',
          real_host     => 'hybrid8.debian.local'
        })
      ],
      [quit => {message => 'Gone to lunch', nick => 'superwoman'}],
    ));
  }
);

$server->subtest(
  'internal irc commands does not cause events' => sub {
    $server->server_write_ok(
      ":supergirl!u2\@example.com PRIVMSG mojo_irc :\x{1}PING 1393007660\x{1}\r\n")
      ->client_event_ok('_irc_event_ctcp_ping')->server_event_ok('_irc_event_ctcpreply_ping')
      ->server_write_ok(":supergirl!u2\@example.com PRIVMSG mojo_irc :\x{1}TIME\x{1}\r\n")
      ->client_event_ok('_irc_event_ctcp_time')->server_event_ok('_irc_event_ctcpreply_time')
      ->server_write_ok(":supergirl!u2\@example.com PRIVMSG mojo_irc :\x{1}VERSION\x{1}\r\n")
      ->client_event_ok('_irc_event_ctcp_version')->server_event_ok('_irc_event_ctcpreply_version')
      ->server_write_ok(":supergirl!u2\@example.com PRIVMSG superman :\x{1}ACTION msg1\x{1}\r\n")
      ->client_event_ok('_irc_event_ctcp_action')->process_ok('basic commands');
    $server->client_states_ok([]);
    $server->client_messages_ok([superhashof({from => 'supergirl'})]);
  }
);

$server->subtest(
  'channel commands' => sub {
    $connection->conversation({name => '#convos'});
    $server->server_write_ok(":localhost 004 superman hybrid8.debian.local hybrid-")
      ->server_write_ok(
      "1:8.2.0+dfsg.1-2 DFGHRSWabcdefgijklnopqrsuwxy bciklmnoprstveIMORS bkloveIh\r\n")
      ->client_event_ok('_irc_event_rpl_myinfo')
      ->server_write_ok(":superwoman!sw\@localhost JOIN :#convos\r\n")
      ->client_event_ok('_irc_event_join')
      ->server_write_ok(":superwoman!sw\@localhost KICK #convos superwoman :superman\r\n")
      ->client_event_ok('_irc_event_kick')
      ->server_write_ok(":superman!sm\@localhost MODE #convos +i :superwoman\r\n")
      ->client_event_ok('_irc_event_mode')
      ->server_write_ok(":supergirl!sg\@localhost NICK :superduper\r\n")
      ->client_event_ok('_irc_event_nick')
      ->server_write_ok(":superduper!sd\@localhost PART #convos :I'm out\r\n")
      ->client_event_ok('_irc_event_part')
      ->server_write_ok(":superwoman!sw\@localhost TOPIC #convos :Too cool!\r\n")
      ->client_event_ok('_irc_event_topic')->process_ok('channel commands');

    $server->client_states_ok(bag(
      [join        => {conversation_id => '#convos',    nick     => 'superwoman'}],
      [nick_change => {new_nick        => 'superduper', old_nick => 'supergirl'}],
      [part        => {conversation_id => '#convos', message => 'I\'m out', nick => 'superduper'}],
      [
        me => {
          authenticated           => false,
          capabilities            => {},
          available_channel_modes => 'bciklmnoprstveIMORS',
          available_user_modes    => 'DFGHRSWabcdefgijklnopqrsuwxy',
          nick                    => 'superman',
          real_host               => 'hybrid8.debian.local',
          version                 => 'hybrid-1:8.2.0+dfsg.1-2',
        }
      ],
      [
        part => {
          conversation_id => '#convos',
          kicker          => 'superwoman',
          message         => 'superman',
          nick            => 'superwoman',
        }
      ],
      [
        frozen => {
          connection_id   => 'irc-localhost',
          conversation_id => '#convos',
          frozen          => '',
          name            => '#convos',
          topic           => 'Too cool!',
          unread          => 0,
          notifications   => 0,
        }
      ]
    ));
  }
);

$server->subtest(
  'unread - private conversation' => sub {
    my $conversation = $connection->conversation({name => 'private_man'});
    $server->server_write_ok(":private_man!~pm@127.0.0.1 PRIVMSG private_man :inc unread\r\n")
      ->client_event_ok('_irc_event_privmsg')
      ->server_write_ok(":superman!~pm@127.0.0.1 PRIVMSG private_man :but only once\r\n")
      ->client_event_ok('_irc_event_privmsg')->process_ok('got private messages');
    is $conversation->unread, 1, 'only one unread';
  }
);

$server->subtest(
  'service account messages to connection' => sub {
    $connection->_irc_event_privmsg({
      command  => 'PRIVMSG',
      params   => ['nickserv', 'test'],
      prefix   => 'superman',
      raw_line => ':superman PRIVMSG nickserv :test'
    });
    $server->server_write_ok(":chanserv!ChanServ@127.0.0.1 PRIVMSG superman :service stuff\r\n")
      ->client_event_ok('_irc_event_privmsg')
      ->server_write_ok(":NickServ!NickServ\@services. NOTICE superman :Invalid command.\r\n")
      ->client_event_ok('_irc_event_notice')->process_ok('got service messages');

    $server->client_messages_ok(
      superbagof(map { superhashof({from => $_}) } qw(superman chanserv NickServ)));

    is_deeply(
      $connection->conversations->map(sub { $_->name })->sort->to_array,
      ['#convos', 'private_man', 'superman'],
      'conversations not created for service accounts'
    );
  }
);

$server->subtest(
  'service account messages to open conversation' => sub {
    my $conversation = $connection->conversation({name => 'nickserv'});
    is $conversation->name, 'nickserv';
    $server->server_write_ok(":ChanServ!ChanServ\@services. NOTICE superman :service stuff\r\n")
      ->client_event_ok('_irc_event_notice')
      ->server_write_ok(":NickServ!NickServ\@1services. PRIVMSG superman :service stuff\r\n")
      ->client_event_ok('_irc_event_privmsg')->process_ok('got service messages');
    $server->client_messages_ok(
      superbagof(map { superhashof({from => $_}) } qw(ChanServ NickServ)));

    my $res;
    $core->backend->messages_p($conversation)->then(sub { $res = shift })->wait;
    cmp_deeply $res->{messages}, [superhashof({from => 'NickServ', message => 'service stuff'})],
      'messages on disk';
  }
);

$server->subtest(
  'notice' => sub {
    $server->server_write_ok(":localhost NOTICE AUTH :*** Found your hostname\r\n")
      ->client_event_ok('_irc_event_notice')->process_ok('notice');

    $server->client_messages_ok([
      superhashof({
        highlight => false,
        from      => 'irc-localhost',
        message   => '*** Found your hostname',
        ts        => re(qr{^\d+}),
        type      => 'notice',
      })
    ]);
  }
);

$server->subtest(
  'reconnect too fast' => sub {
    is $connection->{failed_to_connect}, 0, 'failed_to_connect = 0';
    $server->server_write_ok("ERROR :Trying to reconnect too fast.\r\n")
      ->client_event_ok('_irc_event_error')->process_ok('error');
    is $connection->{failed_to_connect}, 1, 'failed_to_connect = 1';
  }
);

done_testing;
