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

	my $entity_views = Vim::find_entity_views(
		view_type => 'HostSystem'
	);

	foreach my $entity_view (@$entity_views) {
		printf("%30s\n", $entity_view->name);
		$ESX->{$entity_view->name} = {};
	}

}


sub get_esx_host_datastores {

	foreach my $esxhost (sort keys %{$ESX}) {

		my $ds_name = undef;
		my $ds_type = undef;
		my $ds_path = undef;

		if ($debug) { printf("processing host %s\n", $esxhost); }

		$ESX->{$esxhost}->{datastores} = ();

		my $host = Vim::find_entity_view(
			view_type => 'HostSystem',
			filter => {
				'summary.config.name' => qr/${esxhost}/
			}
		);

		for (my $i=0; $i < scalar(@{$host->config->fileSystemVolume->mountInfo}); $i++) {

			my $ds_type = $host->config->fileSystemVolume->mountInfo->[$i]->volume->type;
			my $ds_name = $host->config->fileSystemVolume->mountInfo->[$i]->volume->name;
			my $ds_path = $host->config->fileSystemVolume->mountInfo->[$i]->mountInfo->path;
			if ($debug) { printf("processing datastore %s\n", $ds_name); }

			if (!$ds_name or ($ds_type eq "other")) { next; }

			push(@{$ESX->{$esxhost}->{datastores}}, $ds_name);
			if (!$DATASTORE->{$ds_name}) { 

				$DATASTORE->{$ds_name} = {};
				$DATASTORE->{$ds_name}->{path} = $ds_path;

				if ($debug) { 
					printf("i: %3d, name: %s, path: %s\n", $i, $ds_name, $ds_path);
				}

				for (my $j=0; $j < scalar(@{$host->config->fileSystemVolume->mountInfo->[$i]->volume->extent}); $j++) {
			     		if ($debug) { printf("extent: %s\n", $host->config->fileSystemVolume->mountInfo->[$i]->volume->extent->[$j]->diskName); }
					push(@{$DATASTORE->{$ds_name}->{extents}}, $host->config->fileSystemVolume->mountInfo->[$i]->volume->extent->[$j]->diskName);
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

	my $entity_views = Vim::find_entity_views(
		view_type => 'Datastore',
		filter => { 
			'summary.name' => qr/${ds_name}/ 
		}
	);


	foreach my $entity_view (@$entity_views) { 
	
		my $entity_name = $entity_view->summary->name;

		next, if (!$entity_view->vm);

		for (my $i=0; $i < scalar(@{$entity_view->vm}); $i++) {

			my $vm = Vim::get_view(mo_ref => $entity_view->vm->[$i]);

			#print LOG Dumper $vm;

			next, if ($vm->config->template == 1);
			next, if ($VM->{$vm->name});

			if ($debug) { printf("processing VM: %s\n", $vm->name); }
			if ($vm->name) { 
				if ($debug) { printf("VM: %s\n", $vm->name); }
				push(@{$DATASTORE->{$ds_name}->{vms}}, $vm->name);
				$VM->{$vm->name} = {};
			}
			if ($vm->guest->guestFullName) { 
				if ($debug) { printf("\t%s\n", $vm->guest->guestFullName); }
				$VM->{$vm->name}->{guestFullName} = $vm->guest->guestFullName;
			}
			if ($vm->guest->ipAddress) { 
				if ($debug) { printf("\t%s\n", $vm->guest->ipAddress); }
				$VM->{$vm->name}->{ipAddress} = $vm->guest->ipAddress;
			}

			if (!$vm->guest->disk) {
				$VM->{$vm->name}->{non_datastore_resident} = $ds_name;
				next;
			}
			$VM->{$vm->name}->{datastore_resident} = $ds_name;
			for (my $j=0; $j < scalar(@{$vm->guest->disk}); $j++) {
				my $cap = &convert_capacity($vm->guest->disk->[$j]->capacity);
				my $diskpath = $vm->guest->disk->[$j]->diskPath;
				if ($debug) { printf("\t%s\t%s", $diskpath, $cap); }
				$VM->{$vm->name}->{disks}->{$diskpath} = $cap;
			}
			if ($vm->config->extraConfig) {
				foreach my $options (@{$vm->config->extraConfig}) {
					if ($options->key eq "hbr_filter.rpo") {
						$VM->{$vm->name}->{vsphere_rpo} = $options->value;
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

