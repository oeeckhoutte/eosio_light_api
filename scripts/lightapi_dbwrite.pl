use strict;
use warnings;
use JSON;
use Getopt::Long;
use DBI;
use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;
use Digest::SHA qw(sha256_hex);

$Protocol::WebSocket::Frame::MAX_PAYLOAD_SIZE = 100*1024*1024;
$Protocol::WebSocket::Frame::MAX_FRAGMENTS_AMOUNT = 102400;

$| = 1;

my $port = 8800;
my $ack_every = 120;

my $network;

my $dsn = 'DBI:MariaDB:database=lightapi;host=localhost';
my $db_user = 'lightapi';
my $db_password = 'ce1Shish';

my $pre18;

my $ok = GetOptions
    ('network=s' => \$network,
     'port=i'    => \$port,
     'ack=i'     => \$ack_every,     
     'dsn=s'     => \$dsn,
     'dbuser=s'  => \$db_user,
     'dbpw=s'    => \$db_password,
     'pre18'     => \$pre18);


if( not $ok or scalar(@ARGV) > 0 or not $network )
{
    print STDERR "Usage: $0 --network=eos [options...]\n",
    "The utility opens a WS port for Chronicle to send data to.\n",
    "Options:\n",
    "  --port=N           \[$port\] TCP port to listen to websocket connection\n",
    "  --ack=N            \[$ack_every\] Send acknowledgements every N blocks\n",
    "  --network=NAME     name of EOS network\n",
    "  --dsn=DSN          \[$dsn\]\n",
    "  --dbuser=USER      \[$db_user\]\n",
    "  --dbpw=PASSWORD    \[$db_password\]\n",
    "  --pre18            nodeos prior to version 1.8\n";
    exit 1;
}

our $db;
my $json = JSON->new;

my $presicion;

my $confirmed_block = 0;
my $unconfirmed_block = 0;
my $irreversible = 0;

getdb();
{
    my $sth = $db->{'dbh'}->prepare
        ('SELECT decimals FROM NETWORKS WHERE network=?');
    $sth->execute($network);
    my $r = $sth->fetchall_arrayref();
    die("Unknown network: $network") if scalar(@{$r}) == 0;
    my $decimals = $r->[0][0];
    $presicion = 10**$decimals;
}
{
    my $sth = $db->{'dbh'}->prepare
        ('SELECT block_num, irreversible FROM SYNC WHERE network=?');
    $sth->execute($network);
    my $r = $sth->fetchall_arrayref();
    if( scalar(@{$r}) > 0 )
    {
        $confirmed_block = $r->[0][0];
        $irreversible = $r->[0][1];
    }
}


Net::WebSocket::Server->new(
    listen => $port,
    on_connect => sub {
        my ($serv, $conn) = @_;
        $conn->on(
            'binary' => sub {
                my ($conn, $msg) = @_;
                my ($msgtype, $opts, $js) = unpack('VVa*', $msg);
                my $data = eval {$json->decode($js)};
                if( $@ )
                {
                    print STDERR $@, "\n\n";
                    print STDERR $js, "\n";
                    exit;
                } 
                
                my $ack = process_data($msgtype, $data, \$js);
                if( $ack > 0 )
                {
                    $conn->send_binary(sprintf("%d", $ack));
                    print STDERR "ack $ack\n";
                }
            },
            'disconnect' => sub {
                if( defined($db->{'dbh'}) )
                {
                    $db->{'dbh'}->disconnect();
                    delete $db->{'dbh'};
                }
                print STDERR "Disconnected\n";
            },
            
            );
    },
    )->start;


sub process_data
{
    my $msgtype = shift;
    my $data = shift;
    my $jsptr = shift;

    if( $msgtype == 1001 ) # CHRONICLE_MSGTYPE_FORK
    {
        my $block_num = $data->{'block_num'};
        print STDERR "fork at $block_num\n";

        getdb();
        $db->{'sth_fork_sync'}->execute($block_num, $network);
        $db->{'sth_fork_currency'}->execute($network, $block_num);
        $db->{'sth_fork_auth'}->execute($network, $block_num);
        $db->{'sth_fork_linkauth'}->execute($network, $block_num);
        $db->{'sth_fork_delband'}->execute($network, $block_num);
        $db->{'sth_fork_codehash'}->execute($network, $block_num);
        $db->{'sth_fork_userres'}->execute($network, $block_num);
        $db->{'dbh'}->commit();
        $confirmed_block = $block_num-1;
        $unconfirmed_block = $block_num-1;
        return $confirmed_block;
    }
    elsif( $msgtype == 1007 ) # CHRONICLE_MSGTYPE_TBL_ROW
    {
        my $kvo = $data->{'kvo'};
        if( ref($kvo->{'value'}) eq 'HASH' )
        {
            if( $kvo->{'table'} eq 'accounts' )
            {
                if( defined($kvo->{'value'}{'balance'}) and
                    $kvo->{'scope'} =~ /^[a-z0-5.]+$/ )
                {
                    my $bal = $kvo->{'value'}{'balance'};
                    if( $bal =~ /^([0-9.]+) ([A-Z]{1,7})$/ )
                    {
                        my $amount = $1;
                        my $currency = $2;
                        my $block_time = $data->{'block_timestamp'};
                        $block_time =~ s/T/ /;
                        
                        my $decimals = 0;
                        my $pos = index($amount, '.');
                        if( $pos > -1 )
                        {
                            $decimals = length($amount) - $pos - 1;
                        }
                        
                        $db->{'sth_upd_currency'}->execute
                            ($network, $kvo->{'scope'}, $data->{'block_num'}, $block_time,
                             $kvo->{'code'}, $currency, $amount, $decimals,
                             ($data->{'added'} eq 'true')?0:1);
                    }
                }
            }
            elsif( $kvo->{'code'} eq 'eosio' )
            {
                if( $kvo->{'table'} eq 'delband' )
                {
                    my ($cpu, $curr1) = split(/\s/, $kvo->{'value'}{'cpu_weight'});
                    my ($net, $curr2) = split(/\s/, $kvo->{'value'}{'net_weight'});
                    my $block_time = $data->{'block_timestamp'};
                    $block_time =~ s/T/ /;
                    
                    $db->{'sth_upd_delband'}->execute
                        ($network, $kvo->{'value'}{'to'}, $data->{'block_num'}, $block_time,
                         $kvo->{'value'}{'from'}, $cpu*$presicion, $net*$presicion,
                         ($data->{'added'} eq 'true')?0:1);
                }
                elsif( $kvo->{'table'} eq 'userres' )
                {
                    my ($cpu, $curr1) = split(/\s/, $kvo->{'value'}{'cpu_weight'});
                    my ($net, $curr2) = split(/\s/, $kvo->{'value'}{'net_weight'});
                    my $block_time = $data->{'block_timestamp'};
                    $block_time =~ s/T/ /;
                    
                    $db->{'sth_upd_userres'}->execute
                        ($network, $kvo->{'value'}{'owner'}, $data->{'block_num'}, $block_time,
                         $cpu*$presicion, $net*$presicion, $kvo->{'value'}{'ram_bytes'},
                         ($data->{'added'} eq 'true')?0:1);
                }
            }
        }
    }
    elsif( $msgtype == 1003 ) # CHRONICLE_MSGTYPE_TX_TRACE
    {
        my $trace = $data->{'trace'};
        if( $trace->{'status'} eq 'executed' )
        {
            my $block_num = $data->{'block_num'};
            my $block_time = $data->{'block_timestamp'};
            $block_time =~ s/T/ /;

            if( $pre18 )
            {
                process_pre18_traces($trace->{'traces'}, $block_num, $block_time);
            }
            else
            {
                foreach my $atrace ( @{$trace->{'action_traces'}} )
                {
                    my $act = $atrace->{'act'};
                    if( $atrace->{'receipt'}{'receiver'} eq 'eosio' and $act->{'account'} eq 'eosio' )
                    {
                        process_eosio_trace($act->{'name'}, $act->{'data'}, $block_num, $block_time);
                    }
                }
            }
        }
    }
    elsif( $msgtype == 1009 ) # CHRONICLE_MSGTYPE_RCVR_PAUSE
    {
        if( $unconfirmed_block > $confirmed_block )
        {
            $confirmed_block = $unconfirmed_block;
            return $confirmed_block;
        }
    }
    elsif( $msgtype == 1010 ) # CHRONICLE_MSGTYPE_BLOCK_COMPLETED
    {
        getdb();
        my $block_num = $data->{'block_num'};
        my $block_time = $data->{'block_timestamp'};
        $block_time =~ s/T/ /;
        my $last_irreversible = $data->{'last_irreversible'};

        if( $block_num > $unconfirmed_block+1 )
        {
            printf STDERR ("WARNING: missing blocks %d to %d\n", $unconfirmed_block+1, $block_num-1);
        }                           
        
        $db->{'sth_upd_sync_head'}->execute($block_num, $block_time, $last_irreversible, $network);
        $db->{'dbh'}->commit();

        if( $block_num <= $last_irreversible or $last_irreversible > $irreversible )
        {
            ## currency balances
            my $changes = 0;
            $db->{'sth_get_upd_currency'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_currency'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                if( $r->{'deleted'} )
                {
                    $db->{'sth_erase_currency'}->execute
                        ($network, map {$r->{$_}} qw(account_name contract currency));
                }
                else
                {
                    $db->{'sth_save_currency'}->execute
                        ($network, map {$r->{$_}}
                         qw(account_name block_num block_time contract currency amount decimals
                            block_num block_time amount) );
                }
            }
            
            if( $changes )
            {
                $db->{'sth_del_upd_currency'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }

            
            ## authorization
            $changes = 0;
            $db->{'sth_get_upd_auth'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_auth'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                my @arg = ($network, $r->{'account_name'}, $r->{'perm'});
                $db->{'sth_erase_auth_thres'}->execute(@arg);
                $db->{'sth_erase_auth_keys'}->execute(@arg);
                $db->{'sth_erase_auth_acc'}->execute(@arg);

                if( not $r->{'deleted'} )
                {
                    my $auth = $json->decode($r->{'jsdata'});
                    $db->{'sth_save_auth_thres'}->execute
                        (@arg, $auth->{'threshold'}, $r->{'block_num'},$r->{'block_time'});
                    
                    foreach my $keydata (@{$auth->{'keys'}})
                    {
                        $db->{'sth_save_auth_keys'}->execute
                            (@arg, $keydata->{'key'}, $keydata->{'weight'});
                    }
                    
                    foreach my $accdata (@{$auth->{'accounts'}})
                    {
                        $db->{'sth_save_auth_acc'}->execute
                            (@arg, $accdata->{'permission'}{'actor'},
                             $accdata->{'permission'}{'permission'}, $accdata->{'weight'});
                    }
                }
            }

            if( $changes )
            {
                $db->{'sth_del_upd_auth'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }


            ## linkauth
            $changes = 0;
            $db->{'sth_get_upd_linkauth'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_linkauth'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                if( $r->{'deleted'} )
                {
                    $db->{'sth_erase_linkauth'}->execute
                        ($network, map {$r->{$_}} qw(account_name code type));
                }
                else
                {
                    $db->{'sth_save_linkauth'}->execute
                        ($network, map {$r->{$_}}
                         qw(account_name code type requirement block_num block_time
                            requirement block_num block_time));
                }
            }

            if( $changes )
            {
                $db->{'sth_del_upd_linkauth'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }
            
            
            ## delegated bandwidth
            $changes = 0;
            $db->{'sth_get_upd_delband'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_delband'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                if( $r->{'deleted'} )
                {
                    $db->{'sth_erase_delband'}->execute
                        ($network, $r->{'account_name'}, $r->{'del_from'});
                }
                else
                {
                    $db->{'sth_save_delband'}->execute
                        ($network, map {$r->{$_}}
                         qw(account_name del_from block_num block_time cpu_weight net_weight
                            block_num block_time cpu_weight net_weight));
                }
            }

            if( $changes )
            {
                $db->{'sth_del_upd_delband'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }


            ## setcode
            $changes = 0;
            $db->{'sth_get_upd_codehash'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_codehash'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                if( $r->{'deleted'} )
                {
                    $db->{'sth_erase_codehash'}->execute($network, $r->{'account_name'});
                }
                else
                {
                    $db->{'sth_save_codehash'}->execute
                        ($network, map {$r->{$_}}
                         qw(account_name block_num block_time code_hash block_num block_time code_hash));
                }
            }
            
            if( $changes )
            {
                $db->{'sth_del_upd_codehash'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }
            
            ## userres
            $changes = 0;
            $db->{'sth_get_upd_userres'}->execute($network, $last_irreversible);
            while(my $r = $db->{'sth_get_upd_userres'}->fetchrow_hashref('NAME_lc'))
            {
                $changes = 1;
                if( $r->{'deleted'} )
                {
                    $db->{'sth_erase_userres'}->execute($network, $r->{'account_name'});
                }
                else
                {
                    $db->{'sth_save_userres'}->execute
                        ($network, map {$r->{$_}}
                         qw(account_name block_num block_time cpu_weight net_weight ram_bytes
                            block_num block_time cpu_weight net_weight ram_bytes));
                }
            }

            if( $changes )
            {
                $db->{'sth_del_upd_userres'}->execute($network, $last_irreversible);
                $db->{'dbh'}->commit();
            }

            $irreversible = $last_irreversible;
        }                   
        
        $unconfirmed_block = $block_num;
        if( $unconfirmed_block - $confirmed_block >= $ack_every )
        {
            $confirmed_block = $unconfirmed_block;
            return $confirmed_block;
        }
    }
    return 0;
}



sub process_pre18_traces
{
    my $traces = shift;
    my $block_num = shift;
    my $block_time = shift;

    foreach my $atrace (@{$traces})
    {
        if( $atrace->{'receipt'}{'receiver'} eq 'eosio' and $atrace->{'account'} eq 'eosio' )
        {
            process_eosio_trace($atrace->{'name'}, $atrace->{'data'}, $block_num, $block_time);
        }

        if( defined($atrace->{'inline_traces'}) )
        {
            process_pre18_traces($atrace->{'inline_traces'}, $block_num, $block_time);
        }
    }
}



sub process_eosio_trace
{
    my $aname = shift;
    my $data = shift;
    my $block_num = shift;
    my $block_time = shift;

    return if (ref($data) ne 'HASH');

    if( $aname eq 'newaccount' )
    {
        my $name = $data->{'name'};
        if( not defined($name) )
        {
            # workaround for https://github.com/EOSIO/eosio.contracts/pull/129
            $name = $data->{'newact'};
        }
        
        $db->{'sth_upd_auth'}->execute
            ($network, $name, $block_num, $block_time, 'owner',
             $json->encode($data->{'owner'}), 0);
        
        $db->{'sth_upd_auth'}->execute
            ($network, $name, $block_num, $block_time, 'active',
             $json->encode($data->{'active'}), 0);
    }
    elsif( $aname eq 'updateauth' )
    {
        $db->{'sth_upd_auth'}->execute
            ($network, $data->{'account'}, $block_num, $block_time,
             $data->{'permission'}, $json->encode($data->{'auth'}), 0);
    }
    elsif( $aname eq 'deleteauth' )
    {
        $db->{'sth_upd_auth'}->execute
            ($network, $data->{'account'}, $block_num, $block_time,
             $data->{'permission'}, '{}', 1);
    }
    elsif( $aname eq 'setcode' )
    {
        my $hash = '';
        my $deleted = 1;
        
        if( length($data->{'code'}) > 0 )
        {
            $hash = sha256_hex(pack('H*', $data->{'code'}));
            $deleted = 0;
        }
        
        $db->{'sth_upd_codehash'}->execute
            ($network, $data->{'account'}, $block_num, $block_time,
             $hash, $deleted);
    }
    elsif( $aname eq 'linkauth' )
    {
        $db->{'sth_upd_linkauth'}->execute
            ($network, map({$data->{$_}} qw(account code type requirement)),
             $block_num, $block_time, 0);
    }
    elsif( $aname eq 'unlinkauth' )
    {
        $db->{'sth_upd_linkauth'}->execute
            ($network, map({$data->{$_}} qw(account code type)), '',
             $block_num, $block_time, 1);
    }
}

        

sub getdb
{
    if( defined($db) and defined($db->{'dbh'}) and $db->{'dbh'}->ping() )
    {
        return;
    }

    my $dbh = $db->{'dbh'} = DBI->connect($dsn, $db_user, $db_password,
                                          {'RaiseError' => 1, AutoCommit => 0,
                                           mariadb_server_prepare => 1});
    die($DBI::errstr) unless $dbh;

    $db->{'sth_fork_sync'} = $dbh->prepare
        ('UPDATE SYNC SET block_num=? WHERE network = ?');

    $db->{'sth_fork_currency'} = $dbh->prepare
        ('DELETE FROM UPD_CURRENCY_BAL WHERE network = ? AND block_num >= ? ');

    $db->{'sth_fork_auth'} = $dbh->prepare
        ('DELETE FROM UPD_AUTH WHERE network = ? AND block_num >= ? ');

    $db->{'sth_fork_linkauth'} = $dbh->prepare
        ('DELETE FROM UPD_LINKAUTH WHERE network = ? AND block_num >= ? ');
    
    $db->{'sth_fork_delband'} = $dbh->prepare
        ('DELETE FROM UPD_DELBAND WHERE network = ? AND block_num >= ? ');

    $db->{'sth_fork_codehash'} = $dbh->prepare
        ('DELETE FROM UPD_CODEHASH WHERE network = ? AND block_num >= ? ');

    $db->{'sth_fork_userres'} = $dbh->prepare
        ('DELETE FROM UPD_CODEHASH WHERE network = ? AND block_num >= ? ');

    
    $db->{'sth_upd_currency'} = $dbh->prepare
        ('INSERT INTO UPD_CURRENCY_BAL ' . 
         '(network, account_name, block_num, block_time, contract, currency, amount, decimals, deleted) ' .
         'VALUES(?,?,?,?,?,?,?,?,?)');

    $db->{'sth_upd_auth'} = $dbh->prepare
        ('INSERT INTO UPD_AUTH ' . 
         '(network, account_name, block_num, block_time, perm, jsdata, deleted) ' .
         'VALUES(?,?,?,?,?,?,?)');

    $db->{'sth_upd_delband'} = $dbh->prepare
        ('INSERT INTO UPD_DELBAND ' . 
         '(network, account_name, block_num, block_time, del_from, cpu_weight, net_weight, deleted) ' .
         'VALUES(?,?,?,?,?,?,?,?)');

    $db->{'sth_upd_codehash'} = $dbh->prepare
        ('INSERT INTO UPD_CODEHASH ' . 
         '(network, account_name, block_num, block_time, code_hash, deleted) ' .
         'VALUES(?,?,?,?,?,?)');

    $db->{'sth_upd_linkauth'} = $dbh->prepare
        ('INSERT INTO UPD_LINKAUTH ' . 
         '(network, account_name, code, type, requirement, block_num, block_time, deleted) ' .
         'VALUES(?,?,?,?,?,?,?,?)');
    
    $db->{'sth_upd_userres'} = $dbh->prepare
        ('INSERT INTO UPD_USERRES ' . 
         '(network, account_name, block_num, block_time, cpu_weight, net_weight, ram_bytes, deleted) ' .
         'VALUES(?,?,?,?,?,?,?,?)');

    
    $db->{'sth_upd_sync_head'} = $dbh->prepare
        ('UPDATE SYNC SET block_num=?, block_time=?, irreversible=? WHERE network = ?');


    
    $db->{'sth_get_upd_currency'} = $dbh->prepare
        ('SELECT account_name, block_num, block_time, contract, currency, amount, decimals, deleted ' .
         'FROM UPD_CURRENCY_BAL WHERE network = ? AND block_num <= ? ORDER BY id');
        
    $db->{'sth_erase_currency'} = $dbh->prepare
        ('DELETE FROM CURRENCY_BAL WHERE ' .
         'network=? and account_name=? and contract=? AND currency=?');
    
    $db->{'sth_save_currency'} = $dbh->prepare
        ('INSERT INTO CURRENCY_BAL ' .
         '(network, account_name, block_num, block_time, contract, currency, amount, decimals) ' .
         'VALUES(?,?,?,?,?,?,?,?) ' .
         'ON DUPLICATE KEY UPDATE block_num=?, block_time=?, amount=?');

    $db->{'sth_del_upd_currency'} = $dbh->prepare
        ('DELETE FROM UPD_CURRENCY_BAL WHERE network = ? AND block_num <= ?');



    
    $db->{'sth_get_upd_auth'} = $dbh->prepare
        ('SELECT account_name, block_num, block_time, perm, jsdata, deleted ' .
         'FROM UPD_AUTH WHERE network = ? AND block_num <= ? ORDER BY id');

    $db->{'sth_erase_auth_thres'} = $dbh->prepare
        ('DELETE FROM AUTH_THRESHOLDS WHERE ' .
         'network=? AND account_name=? AND perm=?');

    $db->{'sth_erase_auth_keys'} = $dbh->prepare
        ('DELETE FROM AUTH_KEYS WHERE ' .
         'network=? AND account_name=? AND perm=?');

    $db->{'sth_erase_auth_acc'} = $dbh->prepare
        ('DELETE FROM AUTH_ACC WHERE ' .
         'network=? AND account_name=? AND perm=?');

    $db->{'sth_save_auth_thres'} = $dbh->prepare
        ('INSERT INTO AUTH_THRESHOLDS ' .
         '(network, account_name, perm, threshold, block_num, block_time) ' .
         'VALUES(?,?,?,?,?,?)');

    $db->{'sth_save_auth_keys'} = $dbh->prepare
        ('INSERT INTO AUTH_KEYS ' .
         '(network, account_name, perm, pubkey, weight) ' .
         'VALUES(?,?,?,?,?)');

    $db->{'sth_save_auth_acc'} = $dbh->prepare
        ('INSERT INTO AUTH_ACC ' .
         '(network, account_name, perm, actor, permission, weight) ' .
         'VALUES(?,?,?,?,?,?)');

    $db->{'sth_del_upd_auth'} = $dbh->prepare
        ('DELETE FROM UPD_AUTH WHERE network = ? AND block_num <= ?');


    
    $db->{'sth_get_upd_linkauth'} = $dbh->prepare
        ('SELECT account_name, code, type, requirement, block_num, block_time, deleted ' .
         'FROM UPD_LINKAUTH WHERE network = ? AND block_num <= ? ORDER BY id');

    $db->{'sth_erase_linkauth'} = $dbh->prepare
        ('DELETE FROM LINKAUTH WHERE ' .
         'network=? AND account_name=? AND code=? AND type=?');

    $db->{'sth_save_linkauth'} = $dbh->prepare
        ('INSERT INTO LINKAUTH ' .
         '(network, account_name, code, type, requirement, block_num, block_time) ' .
         'VALUES(?,?,?,?,?,?,?) ' .
         'ON DUPLICATE KEY UPDATE requirement=?, block_num=?, block_time=?');

    $db->{'sth_del_upd_linkauth'} = $dbh->prepare
        ('DELETE FROM UPD_LINKAUTH WHERE network = ? AND block_num <= ?');
    

    
    $db->{'sth_get_upd_delband'} = $dbh->prepare
        ('SELECT account_name, block_num, block_time, del_from, cpu_weight, net_weight, deleted ' .
         'FROM UPD_DELBAND WHERE network = ? AND block_num <= ? ORDER BY id');

    $db->{'sth_erase_delband'} = $dbh->prepare
        ('DELETE FROM DELBAND WHERE network = ? AND account_name = ? AND del_from = ?');
    
    $db->{'sth_save_delband'} = $dbh->prepare
        ('INSERT INTO DELBAND ' .
         '(network, account_name, del_from, block_num, block_time, cpu_weight, net_weight) ' .
         'VALUES(?,?,?,?,?,?,?) ' .
         'ON DUPLICATE KEY UPDATE block_num=?, block_time=?, cpu_weight=?, net_weight=?');

    $db->{'sth_del_upd_delband'} = $dbh->prepare
        ('DELETE FROM UPD_DELBAND WHERE network = ? AND block_num <= ?');    



    $db->{'sth_get_upd_codehash'} = $dbh->prepare
        ('SELECT account_name, block_num, block_time, code_hash, deleted ' .
         'FROM UPD_CODEHASH WHERE network = ? AND block_num <= ? ORDER BY id');
    
    $db->{'sth_erase_codehash'} = $dbh->prepare
        ('DELETE FROM CODEHASH WHERE ' .
         'network=? and account_name=?');
    
    $db->{'sth_save_codehash'} = $dbh->prepare
        ('INSERT INTO CODEHASH ' .
         '(network, account_name, block_num, block_time, code_hash) ' .
         'VALUES(?,?,?,?,?) ' .
         'ON DUPLICATE KEY UPDATE block_num=?, block_time=?, code_hash=?');

    $db->{'sth_del_upd_codehash'} = $dbh->prepare
        ('DELETE FROM UPD_CODEHASH WHERE network = ? AND block_num <= ?');    


    
    $db->{'sth_get_upd_userres'} = $dbh->prepare
        ('SELECT account_name, block_num, block_time, cpu_weight, net_weight, ram_bytes, deleted ' .
         'FROM UPD_USERRES WHERE network = ? AND block_num <= ? ORDER BY id');

    $db->{'sth_erase_userres'} = $dbh->prepare
        ('DELETE FROM USERRES WHERE network = ? AND account_name = ?');
    
    $db->{'sth_save_userres'} = $dbh->prepare
        ('INSERT INTO USERRES ' .
         '(network, account_name, block_num, block_time, cpu_weight, net_weight, ram_bytes) ' .
         'VALUES(?,?,?,?,?,?,?) ' .
         'ON DUPLICATE KEY UPDATE block_num=?, block_time=?, cpu_weight=?, net_weight=?, ram_bytes=?');

    $db->{'sth_del_upd_userres'} = $dbh->prepare
        ('DELETE FROM UPD_USERRES WHERE network = ? AND block_num <= ?');    
}
