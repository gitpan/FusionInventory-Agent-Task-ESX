package FusionInventory::VMware::SOAP;

use strict;
use warnings;

use XML::TreePP;
use LWP::UserAgent;
use HTTP::Cookies;

use FusionInventory::Agent;
use FusionInventory::VMware::SOAP::Host;

sub new {
    my (undef, $params) = @_;

    my $self = {
        ua => LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 }),
        url => $params->{url},
        debugDir => $params->{debugDir},
        lastError => ""
    };

    $self->{ua}->agent('FusionInventory-Agent_v'.$FusionInventory::Agent::VERSION);

    my $cookie = new HTTP::Cookies( ignore_discard => 1 );
    $self->{ua}->cookie_jar( $cookie );

    push @{ $self->{ua}->requests_redirectable }, 'POST';
    $self->{ua}->agent("VMware::PoorBoySOAP/0.1 ");

    $self->{tpp} = XML::TreePP->new(force_array => [qw( returnval propSet )]);
    return bless $self;
}


sub _loadSOAPDump {
    my ($self, $name) = @_;

    my $content;
    open (FILE, "<". $self->{debugDir}."/".$name.".soap") or die "failed to open ".$self->{debugDir}.'/'.$name.".soap";
    $/ = undef;
    $content = <FILE>;
    close FILE;

    return $content;
}

sub _storeSOAPDump {
    return; # DEBUG
    my ($self, $action, $data) = @_;
    open(FILE, ">$action.soap") or die;
    print FILE $data;
    close FILE
}

sub _send {
    my ($self, $action, $name, $xmlToSend) = @_;

    if ($self->{debugDir}) {
        return $self->_loadSOAPDump ($name);
    }


    my $req = HTTP::Request->new(POST => $self->{url});
    $req->content($xmlToSend);
    $req->{_headers}->{soapaction} = "\"urn:vim25#".$action."\"";
    $req->{_headers}->{accept} = ['text/xml', 'application/soap' ];
    $req->{_headers}->{'content-length'} = length($xmlToSend);
    $req->{_protocol} = 'HTTP/1.1';
    $req->content_type('text/xml; charset=utf-8');

    my $res = $self->{ua}->request($req);

    if ($res->is_success) {
        $self->_storeSOAPDump($name, $res->content);
        return $res->content;
    } else {
        my $err = $res->content;
        my $tmpRef = {};

        eval {
            $err =~ s/.*(<faultstring>.*<\/faultstring>).*/$1/sg;
            $tmpRef = $self->{tpp}->parse($err);
        };

        my $errorString = $res->status_line;
        if ($tmpRef && $tmpRef->{faultstring}) {
            $errorString .= ": ".$tmpRef->{faultstring};
        }
        print STDERR $errorString."\n";
        $self->{lastError} = $errorString;
        return;
    }

    return 1;
}

sub _parseAnswer {
    my ($self, $answer) = @_;

    return unless $answer;
    undef $/;

# We simplify the XML structure
    my $pattern = '.*<\w+Response xmlns="urn:vim25">(.+)</\w+Response>.*$';
    $answer =~ s/$pattern/$1/sg,;
    $answer =~ s/ (xsi:|)type="[:\w]+"//sg;
    $answer =~ s/[[:cntrl:]]//g;
    my $tmpRef = $self->{tpp}->parse($answer);

    my $ref = [];
    foreach (@{$tmpRef->{returnval}}) {
        if ($_->{propSet}) {
            my %tmp;
            foreach my $p (@{$_->{propSet}}) {
                next unless $p->{val};
                $tmp{$p->{name}} = $p->{val}
            }
            push @$ref, \%tmp;
        } else {
            push @$ref, $_;
        }
    }

    return $ref;

}

sub connect {
    my ($self, $user, $password) = @_;

    my $req = '<?xml version="1.0" encoding="UTF-8"?>
   <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                     xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
   <soapenv:Body>
<RetrieveServiceContent xmlns="urn:vim25"><_this type="ServiceInstance">ServiceInstance</_this>
</RetrieveServiceContent></soapenv:Body></soapenv:Envelope>';


    my $answer = $self->_send('ServiceInstance', 'ServiceInstance', $req);
    return unless $answer;

    my $serviceInstance = $self->_parseAnswer($answer);
    return unless $serviceInstance;

    if ($serviceInstance->[0]{about}{apiType} eq 'VirtualCenter') {
        $self->{vcenter} = 1; # TODO
        $self->{sessionManager} = "SessionManager";
        $self->{propertyCollector} = "propertyCollector";
    } else {
        $self->{vcenter} = 0;
        $self->{sessionManager} = "ha-sessionmgr";
        $self->{propertyCollector} = "ha-property-collector";
    }


    $req =
        '<?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:xsd="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soapenv:Body>
        <Login xmlns="urn:vim25"><_this type="SessionManager">%s</_this>
        <userName>%s</userName><password>%s</password></Login></soapenv:Body></soapenv:Envelope>';

    $answer = $self->_send('Login', 'Login', sprintf($req, $self->{sessionManager}, $user, $password));
    return unless $answer;
    return if $answer =~ /ServerFaultCode/m;

    return $self->_parseAnswer($answer);

}

#sub getHostInfo {
#    my ($self) = @_;
#
#
#    my $req =
#        '<?xml version="1.0" encoding="UTF-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" soap:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><RetrieveServiceContent xmlns="urn:vim25"><_this type="ServiceInstance">ServiceInstance</_this></RetrieveServiceContent></soap:Body></soap:Envelope>';
#
#
#    my $answer = $self->_send('RetrieveServiceContent', 'RetrieveServiceContent', $req);
#    my $ref = $self->_parseAnswer($answer);
#
#    return $host;
#}


sub _getVirtualMachineList {
    my ($self) = @_;

    my $req =

        '<?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:xsd="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soapenv:Body>
        <RetrieveProperties xmlns="urn:vim25"><_this type="PropertyCollector">ha-property-collector</_this>
        <specSet><propSet><type>VirtualMachine</type><all>0</all></propSet><objectSet><obj type="Folder">ha-folder-root</obj>
        <skip>0</skip><selectSet xsi:type="TraversalSpec"><name>folderTraversalSpec</name><type>Folder</type><path>childEntity</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet><selectSet><name>datacenterHostTraversalSpec</name></selectSet><selectSet><name>datacenterVmTraversalSpec</name></selectSet><selectSet><name>datacenterDatastoreTraversalSpec</name></selectSet><selectSet><name>datacenterNetworkTraversalSpec</name></selectSet><selectSet><name>computeResourceRpTraversalSpec</name></selectSet><selectSet><name>computeResourceHostTraversalSpec</name></selectSet><selectSet><name>hostVmTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterDatastoreTraversalSpec</name><type>Datacenter</type><path>datastoreFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterNetworkTraversalSpec</name><type>Datacenter</type><path>networkFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterVmTraversalSpec</name><type>Datacenter</type><path>vmFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterHostTraversalSpec</name><type>Datacenter</type><path>hostFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>computeResourceHostTraversalSpec</name><type>ComputeResource</type><path>host</path><skip>0</skip></selectSet><selectSet xsi:type="TraversalSpec"><name>computeResourceRpTraversalSpec</name><type>ComputeResource</type><path>resourcePool</path><skip>0</skip><selectSet><name>resourcePoolTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>resourcePoolTraversalSpec</name><type>ResourcePool</type><path>resourcePool</path><skip>0</skip><selectSet><name>resourcePoolTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>hostVmTraversalSpec</name><type>HostSystem</type><path>vm</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>resourcePoolVmTraversalSpec</name><type>ResourcePool</type><path>vm</path><skip>0</skip></selectSet></objectSet></specSet></RetrieveProperties></soapenv:Body></soapenv:Envelope>
        ';


    my $answer = $self->_send('RetrievePropertiesVMList', 'RetrievePropertiesVMList', $req);
    my $ref = $self->_parseAnswer($answer);
    my @list;
    if (ref($ref) eq 'HASH') {
        push @list, $ref;
    } elsif ($ref) {
        @list = @{$ref};
    }

    my @ids;
    foreach (@list) {
        push @ids, $_->{obj};
    }

    return \@ids;

}

sub _getVirtualMachineById {
    my ($self, $id) = @_;

    my $req = '<?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:xsd="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soapenv:Body>
        <RetrieveProperties xmlns="urn:vim25"><_this type="PropertyCollector">%s</_this>
        <specSet><propSet><type>VirtualMachine</type><all>1</all></propSet><objectSet><obj type="VirtualMachine">%s</obj>
        </objectSet></specSet></RetrieveProperties></soapenv:Body></soapenv:Envelope>
        ';

    my $answer = $self->_send('RetrieveProperties', 'RetrieveProperties-VM-'.$id, sprintf($req, $self->{propertyCollector}, $id));
    return [] unless $answer;

    # hack to preserve  annotation / comment formating
    $answer =~ s/\n/&#10;/gm;

    my $ref = $self->_parseAnswer($answer);
    return $ref;
}

sub getHostFullInfo {
    my ($self, $id) = @_;

    $id = 'ha-host' unless $id;

    my $req = '<?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
        xmlns:xsd="http://www.w3.org/2001/XMLSchema"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soapenv:Body>
        <RetrieveProperties xmlns="urn:vim25"><_this type="PropertyCollector">%s</_this>
        <specSet><propSet><type>HostSystem</type><all>1</all></propSet><objectSet><obj type="HostSystem">%s</obj>
        </objectSet></specSet></RetrieveProperties></soapenv:Body></soapenv:Envelope>
        ';

    my $answer = $self->_send('RetrieveProperties', 'getHostFullInfo', sprintf($req, $self->{propertyCollector}, $id));
    my $ref = $self->_parseAnswer($answer);
    my $vms = [];
    my $machineIdList;
    if (exists($ref->[0]{vm}{ManagedObjectReference})) { # ESX 3.5
        if (ref($ref->[0]{vm}{ManagedObjectReference}) eq 'ARRAY') {
            $machineIdList = $ref->[0]{vm}{ManagedObjectReference};
        } else {
            push @$machineIdList, $ref->[0]{vm}{ManagedObjectReference};
        }
    } else {
        $machineIdList = $self->_getVirtualMachineList();
    }
    #$vm = $ref->[0]{vm};
    foreach my $id (@$machineIdList) {
        push @$vms, $self->_getVirtualMachineById($id);
    }

    my $host = FusionInventory::VMware::SOAP::Host->new($ref, $vms);
    return $host;
}

sub getHostIds {
    my ($self) = @_;


    if (!$self->{vcenter}) {
        return ['ha-host'];
    }

    my $req = '<?xml version="1.0" encoding="UTF-8"?>
   <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                     xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
   <soapenv:Body>
<RetrieveProperties xmlns="urn:vim25"><_this type="PropertyCollector">propertyCollector</_this>
<specSet><propSet><type>HostSystem</type><all>0</all></propSet><objectSet><obj type="Folder">group-d1</obj>
<skip>0</skip><selectSet xsi:type="TraversalSpec"><name>folderTraversalSpec</name><type>Folder</type><path>childEntity</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet><selectSet><name>datacenterHostTraversalSpec</name></selectSet><selectSet><name>datacenterVmTraversalSpec</name></selectSet><selectSet><name>datacenterDatastoreTraversalSpec</name></selectSet><selectSet><name>datacenterNetworkTraversalSpec</name></selectSet><selectSet><name>computeResourceRpTraversalSpec</name></selectSet><selectSet><name>computeResourceHostTraversalSpec</name></selectSet><selectSet><name>hostVmTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterDatastoreTraversalSpec</name><type>Datacenter</type><path>datastoreFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterNetworkTraversalSpec</name><type>Datacenter</type><path>networkFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterVmTraversalSpec</name><type>Datacenter</type><path>vmFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>datacenterHostTraversalSpec</name><type>Datacenter</type><path>hostFolder</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>computeResourceHostTraversalSpec</name><type>ComputeResource</type><path>host</path><skip>0</skip></selectSet><selectSet xsi:type="TraversalSpec"><name>computeResourceRpTraversalSpec</name><type>ComputeResource</type><path>resourcePool</path><skip>0</skip><selectSet><name>resourcePoolTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>resourcePoolTraversalSpec</name><type>ResourcePool</type><path>resourcePool</path><skip>0</skip><selectSet><name>resourcePoolTraversalSpec</name></selectSet><selectSet><name>resourcePoolVmTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>hostVmTraversalSpec</name><type>HostSystem</type><path>vm</path><skip>0</skip><selectSet><name>folderTraversalSpec</name></selectSet></selectSet><selectSet xsi:type="TraversalSpec"><name>resourcePoolVmTraversalSpec</name><type>ResourcePool</type><path>vm</path><skip>0</skip></selectSet></objectSet></specSet></RetrieveProperties></soapenv:Body></soapenv:Envelope>';

    my $answer = $self->_send('RetrieveProperties', 'getESXFullInfo', sprintf($req));
    my $ref = $self->_parseAnswer($answer);

    my @ids;
    foreach (@$ref) {
        push @ids, $_->{obj};
    }

    return \@ids;
}



1;


