package ZApi::Controller::Zapiwrap;
use utf8;
use EV;
use AnyEvent;
use AnyEvent::HTTP;
use Mojo::Base 'Mojolicious::Controller';
use JSON::XS qw(encode_json decode_json);
use Data::Dumper;
use constant {
     SETENV_FILE=>'/etc/zabbix/api/setenv_inframon.conf',
};
my %SETENV;
my ($apiUrl,$authToken);
BEGIN {
 open (my $fhSetEnv,'<',SETENV_FILE) || die 'Cant set environment: '.SETENV_FILE.' not found!';
 %SETENV=map { chomp; $_=~m/^\s*(?<KEY>[A-Za-z0-9_-]+)\s*=\s*(?:(?<Q>["'])(?<VAL>((?!\g{Q}).)*)\g{Q}|(?<VAL>[^'"[:space:]]+?))\s*$/?($+{'KEY'},$+{'VAL'}):('NOTHING','NOWHERE') } grep { $_ !~ m/^\s*(?:#.*)?$/ } <$fhSetEnv>;
 push @INC,split(/\;/,$SETENV{'PERL_LIBS'}) if $SETENV{'PERL_LIBS'};
 close($fhSetEnv);
}

my $flZAPIInit;
sub init {
  my $self=shift;
  my $log=$self->app->log;
  $log->debug('I am pid='.$$.'. Initializing connection to Zabbix API...');
  
  die 'You must specify ZBX_URL in your config '.SETENV_FILE
    unless $apiUrl=$SETENV{'ZBX_URL'};
  unless ($authToken=$SETENV{'ZBX_TOKEN'}) {
    my $cv=AE::cv;
    http_request(
      'POST'=>$apiUrl,
      'headers'=>{'Content-Type'=>'application/json'},
      'body'=>encode_json({'method'=>'user.login', 'jsonrpc'=>'2.0', 'id'=>0, 'params'=>{'user'=>$SETENV{'ZBX_LOGIN'}, 'password'=>$SETENV{'ZBX_PASS'}}}),
    sub {
      $authToken=decode_json($_[0])->{'result'};
      $cv->send;
    });
    $cv->recv;
  }
  
  unless ($authToken and $apiUrl) {
    $log->error('Cant initialize API, check connecton parameters in your config '.SETENV_FILE);
    return
  }
  
  $log->debug('Connection to Zabbix API established succesfully');
  $flZAPIInit=1;
}

sub get_tigger_descr {
  my $self=shift;
  my $logger=$self->app->log;
  $logger->debug('Requested triggers: '.(my $triggerids=$self->param('triggerids') || $self->stash('triggerids') || ''));
  unless ($flZAPIInit) {
    $logger->error('ZApi not initialised yet, so we have to emergency bootstrap now');
    unless ( init() ) {
      $self->res->code(500);
      $self->render({'error'=>'Zabbix API init() failed. Cant process your request'});
    }
  }
  do {
   $self->render('json'=>{'error'=>'There was no triggerids in request parameters'});
   return
  } unless my @triggers=split /,/=>$triggerids;

  $self->render_later;
  my $cv=AE::cv;
  http_request(	
    'POST'=>$apiUrl,
    'headers'=>{'Content-Type'=>'application/json'},
    'body'=>encode_json({'method'=>'trigger.get', 'jsonrpc'=>'2.0', 'id'=>1, 'auth'=>$authToken, 'params'=>{'triggerids'=>\@triggers,'expandDescription'=>1,'output'=>['description']}}),
  sub {
      $self->app->log->debug('DUMP trigger.get answer: '.Dumper(\@_));
      $self->res->headers->access_control_allow_origin('*');
      unless (my $ans=eval { decode_json $_[0] }) {
        $self->res->code(501);
        $self->render('json'=>{'error'=>'Cant decode answer to Zabbix API request as JSON'});
      } elsif ($ans->{'error'}) {
        $self->res->code(404);
        $self->render('json'=>{'error'=>qq(Zabbix API error $ans->{'error'})});        
      } else {
        $self->render('json'=>{map {$_->{'triggerid'}=>$_->{'description'}} @{$ans->{'result'}}}, 'gzip'=>1);
      }
      $cv->send;
  });
  $cv->recv;
}

1;
