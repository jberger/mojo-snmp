use strict;
use warnings;
use Test::More;
use Mojo::SNMP;
use constant TEST_MEMORY => $ENV{TEST_MEMORY} && eval 'use Test::Memory::Cycle; 1';

diag 'Test::Memory::Cycle is not available' unless TEST_MEMORY;
plan skip_all => 'Crypt::DES is required' unless eval 'require Crypt::DES; 1';

my $snmp = Mojo::SNMP->new;
my (@response, @error, $timeout, $finish);

$snmp->concurrent(0);    # required to set up the queue
$snmp->defaults({timeout => 1, community => 'public', username => 'foo'});
$snmp->on(response => sub { push @response, $_[1]->var_bind_list });
$snmp->on(error => sub { note "error: $_[1]"; push @error, $_[1] });
$snmp->on(finish  => sub { $finish++ });
$snmp->on(timeout => sub { $timeout++ });

memory_cycle_ok($snmp) if TEST_MEMORY;
isa_ok $snmp->ioloop,      'Mojo::IOLoop';
isa_ok $snmp->_dispatcher, 'Mojo::SNMP::Dispatcher';
is $snmp->master_timeout,  0, 'master_timeout is disabled by default';
is $snmp->_dispatcher->ioloop, $snmp->ioloop, 'same ioloop';

$snmp->prepare('1.2.3.4', {version => '2c'}, get => [qw/ 1.3.6.1.2.1.1.4.0 /]);
ok $snmp->_pool->{'1.2.3.4|v2c|public|'}, '1.2.3.4 v2c public';

$snmp->prepare('1.2.3.5', get_next => [qw/ 1.3.6.1.2.1.1.6.0 /]);
ok $snmp->_pool->{'1.2.3.5|v2c|public|'}, '1.2.3.5 v2c public';

memory_cycle_ok($snmp) if TEST_MEMORY;

$snmp->prepare(
  '127.0.0.1', {version => '2', community => 'foo'},
  get      => [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /],
  get_next => [qw/ 1.3.6.1.2.1 /],
);
ok $snmp->_pool->{'127.0.0.1|v2c|foo|'}, '127.0.0.1 v2c foo';

$snmp->prepare('127.0.0.1', {retries => '2', community => 'bar', version => 'snmpv1'});
ok $snmp->_pool->{'127.0.0.1|v1|bar|'}, '127.0.0.1 v1 bar';

$snmp->prepare('*', {stash => 123}, get_next => '1.2.3');

is $snmp->{_setup},    5, 'prepare was called six times (stupid test)';
is $snmp->{_requests}, 0, 'and zero requests was prepared';

is_deeply(
  $snmp->_queue,
  [
    ['1.2.3.4|v2c|public|', 'get', ['1.3.6.1.2.1.1.4.0'], {version => '2c'}, undef],
    ['1.2.3.5|v2c|public|', 'get_next', ['1.3.6.1.2.1.1.6.0'], {}, undef],
    [
      '127.0.0.1|v2c|foo|', 'get',
      [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /],
      {version => '2', community => 'foo'}, undef
    ],
    ['127.0.0.1|v2c|foo|', 'get_next', [qw/ 1.3.6.1.2.1 /], {version => '2', community => 'foo'}, undef],

    # *
    ['1.2.3.4|v2c|public|', 'get_next', ['1.2.3'], {stash => 123}, undef],
    ['1.2.3.5|v2c|public|', 'get_next', ['1.2.3'], {stash => 123}, undef],
    ['127.0.0.1|v1|bar|',   'get_next', ['1.2.3'], {stash => 123}, undef],
    ['127.0.0.1|v2c|foo|',  'get_next', ['1.2.3'], {stash => 123}, undef],
  ],
  'queue is set up'
);

memory_cycle_ok($snmp) if TEST_MEMORY;
my $net_snmp = Net::SNMP->new(nonblocking => 1);
my ($guard, @request);
no warnings 'redefine';
*Net::SNMP::get_next_request = sub { shift; push @request, @_ };
*Net::SNMP::get_request      = sub { shift; push @request, @_ };
$net_snmp->{_error}          = 'yikes!';

$snmp->concurrent(2);
$snmp->prepare('*');
is $snmp->{_requests}, 2, 'prepared two requests';
is int(@{$snmp->_queue}), 6, 'eight left in the queue';
is_deeply $request[1], ['1.3.6.1.2.1.1.4.0'], 'varbindlist was passed on to get_request';
is ref $request[3], 'CODE', 'callback was passed on to get_request';
is_deeply $request[5], ['1.3.6.1.2.1.1.6.0'], 'varbindlist was passed on to get_next_request';
is ref $request[7], 'CODE', 'callback was passed on to get_next_request';

# Capture the expected 'yikes!' error.
$snmp->unsubscribe('error');
$snmp->on(error => sub { push @error, $_[1] });
$request[3]->($net_snmp);
$snmp->on(error => sub { note "error: $_[1]"; push @error, $_[1] });

is $snmp->{_requests}, 2, 'callback prepared two requests';
is int(@{$snmp->_queue}), 5, 'seven left in the queue';
is $error[0], 'yikes!', 'on(error) was triggered';

$guard = 10000;
$snmp->ioloop->one_tick while $guard--;
is $finish, 1, 'on(finish) was triggered';

$snmp->master_timeout(0.000001);
$snmp->_setup;
$guard = 10000;
$snmp->ioloop->one_tick while $guard--;
is $timeout, 1, 'on(timeout) was triggered';

done_testing;
