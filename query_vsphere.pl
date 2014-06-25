#!perl -w

use strict;
use Data::Dumper;
use VMware::VIRuntime;

my $ESX = {};
my $DATASTORE = {};
my $VM = ();
 
my $debug = 1;

Opts::parse();
Opts::validate();
Util::connect();

my $log = "C:\\temp\\vmapi.txt";
open (LOG, ">$log") or die "Unable to open $log\n";


sub get_esx_host_list {

	my $host_entity_views = Vim::find_entity_views(
		view_type => 'HostSystem'
	);

	foreach my $host_view (@$host_entity_views) {
		printf("%30s\n", $host_view->name);
		$ESX->{$host_view->name} = {};
	}

}


sub get_esx_host_datastores {

	foreach my $esxhost (sort keys %{$ESX}) {

		my $ds_name = undef;
		my $ds_type = undef;
		my $ds_path = undef;

		if ($debug) { printf("processing host %s\n", $esxhost); }

		$ESX->{$esxhost}->{datastores} = ();

		my $host_view = Vim::find_entity_view(
			view_type => 'HostSystem',
			filter => {
				'summary.config.name' => qr/${esxhost}/
			}
		);

		for (my $i=0; $i < scalar(@{$host_view->config->fileSystemVolume->mountInfo}); $i++) {

			my $ds_type = $host_view->config->fileSystemVolume->mountInfo->[$i]->volume->type;
			my $ds_name = $host_view->config->fileSystemVolume->mountInfo->[$i]->volume->name;
			my $ds_path = $host_view->config->fileSystemVolume->mountInfo->[$i]->mountInfo->path;
			if ($debug) { printf("processing datastore %s\n", $ds_name); }

			if (!$ds_name or ($ds_type eq "other")) { next; }

			push(@{$ESX->{$esxhost}->{datastores}}, $ds_name);
			if (!$DATASTORE->{$ds_name}) { 

				$DATASTORE->{$ds_name} = {};
				$DATASTORE->{$ds_name}->{path} = $ds_path;

				if ($debug) { 
					printf("i: %3d, name: %s, path: %s\n", $i, $ds_name, $ds_path);
				}

				for (my $j=0; $j < scalar(@{$host_view->config->fileSystemVolume->mountInfo->[$i]->volume->extent}); $j++) {
			     		if ($debug) { printf("extent: %s\n", $host_view->config->fileSystemVolume->mountInfo->[$i]->volume->extent->[$j]->diskName); }
					push(@{$DATASTORE->{$ds_name}->{extents}}, $host_view->config->fileSystemVolume->mountInfo->[$i]->volume->extent->[$j]->diskName);
					}
				&get_datastore_vms(${esxhost}, ${ds_name});
			}
		}

		if ($debug) { 
			print "all datastores found for $esxhost\n";
			#print Dumper $ESX;
			#print "-"x20 . "\n";
			#print Dumper $DATASTORE;
		}

	}

}

sub convert_capacity {

	my ($capacity) = @_;
	my $converted = $capacity;
	my $formatted_cap = undef;
	my $metric = "B";

	if ($converted >= 1024**4) { $converted /= 1024**4; $metric = "TB"; }
	elsif ($converted >= 1024**3) { $converted /= 1024**3; $metric = "GB"; }
	elsif ($converted >= 1024**2) { $converted /= 1024**2; $metric = "MB"; }
	elsif ($converted >= 1024) { $converted /= 1024; $metric = "KB"; }
	else { $metric = "B"; }

	$formatted_cap = sprintf("%.2f %2s", $converted, $metric);

	return($formatted_cap);

}

sub get_datastore_vms {


	my ($esxhost, $ds_name) = @_;

	if ($debug) { print "finding $ds_name...\n"; }

	my $datastore_entity_views = Vim::find_entity_views(
		view_type => 'Datastore',
		filter => { 
			'summary.name' => qr/${ds_name}/ 
		}
	);


	foreach my $datastore_view (@$datastore_entity_views) { 
	
		#my $entity_name = $datastore_view->summary->name;

		next, if (!$datastore_view->vm);

		for (my $i=0; $i < scalar(@{$datastore_view->vm}); $i++) {

			my $vm_view = Vim::get_view(mo_ref => $datastore_view->vm->[$i]);

			#print LOG Dumper $vm;

			next, if ($vm_view->config->template == 1);
			next, if ($VM->{$vm_view->name});

			if ($debug) { printf("processing VM: %s\n", $vm_view->name); }
			if ($vm_view->name) { 
				if ($debug) { printf("VM: %s\n", $vm_view->name); }
				push(@{$DATASTORE->{$ds_name}->{vms}}, $vm_view->name);
				$VM->{$vm_view->name} = {};
			}
			if ($vm_view->guest->guestFullName) { 
				if ($debug) { printf("\t%s\n", $vm_view->guest->guestFullName); }
				$VM->{$vm_view->name}->{guestFullName} = $vm_view->guest->guestFullName;
			}
			if ($vm_view->guest->ipAddress) { 
				if ($debug) { printf("\t%s\n", $vm_view->guest->ipAddress); }
				$VM->{$vm_view->name}->{ipAddress} = $vm_view->guest->ipAddress;
			}

			if (!$vm_view->guest->disk) {
				$VM->{$vm_view->name}->{non_datastore_resident} = $ds_name;
				next;
			}
			$VM->{$vm_view->name}->{datastore_resident} = $ds_name;
			for (my $j=0; $j < scalar(@{$vm_view->guest->disk}); $j++) {
				my $cap = &convert_capacity($vm_view->guest->disk->[$j]->capacity);
				my $diskpath = $vm_view->guest->disk->[$j]->diskPath;
				if ($debug) { printf("\t%s\t%s", $diskpath, $cap); }
				$VM->{$vm_view->name}->{disks}->{$diskpath} = $cap;
			}
			if ($vm_view->config->extraConfig) {
				foreach my $options (@{$vm_view->config->extraConfig}) {
					if ($options->key eq "hbr_filter.rpo") {
						$VM->{$vm_view->name}->{vsphere_rpo} = $options->value;
					}
				}
			}
		}

		if ($debug) { 
			print Dumper $ESX;
			print "-"x20 . "\n";
			print Dumper $DATASTORE;
			print "x"x20 . "\n";
			print Dumper $VM;
		}
	}

}

&get_esx_host_list();
&get_esx_host_datastores();

#Util::trace(0, "Found $entity_type: $entity_name\n");

Util::disconnect();
close(LOG);
exit;

