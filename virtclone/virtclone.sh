#!/bin/bash
#
#	Copies /var/lib/libvirt/images/debianbase.img to new hostname.
#	Mounts the new fs and modifies hostname and ssh keys.
#	Adds new uuid and mac address to .xml file, as well as cpu cores and memory if specified.
#	Updates dhcpd.conf on netserv.icarus with static ip if specified.
#
#
#	Usage:
#	./virtclone.sh hostname 
#
#

function usage {
 
	echo "Usage: $0 -n hostname [options]"
	echo -e "\nOptions:"
	echo -e " -a <address>\t\tSpecifies a static IP address for guest"		
	echo -e " -c <num>\t\tNumber of cores the guest can use"
	echo -e " -m <num>\t\tThe amount of memory the guest can use"
	echo -e " -n <hostname>\t\tName for the new KVM guest" 
	echo -e " -A\t\t\tAutostart guest at boot time"
	echo -e " -S\t\t\tStart guest as soon as configuration has finished"
	echo
	exit 2
}
 


while getopts hn:c:m:a:AS option
do
	case "${option}"
	in
		n) newhostname=${OPTARG};;
		c) numcores=${OPTARG};;
		m) memamount=${OPTARG};;
		a) staticip=${OPTARG};;
		A) autostartvm=1;;
		S) startnow=1;;
		h) usage;;
	esac
done
		


if [ ! $newhostname ]
then
	usage
else
	imagefile=$newhostname".img"
fi

#Generates random unicast mac address
tempmac=`od -An -N6 -tx1 /dev/urandom | sed -e 's/^  *//' -e 's/  */:/g' -e 's/:$//' -e 's/^\(.\)[13579bdf]/\10/'`
newmac=`echo $tempmac | sed -e 's/^..:..:../52:54:00/'`

echo "Cloning base machine to "$imagefile"..."
cp /var/lib/libvirt/images/debian7-base.img /var/lib/libvirt/images/$imagefile

echo "Fixing permissions..."
chown libvirt-qemu:libvirt-qemu /var/lib/libvirt/images/$imagefile

echo "Making loop device..."
dmsetup remove_all

kpartx -av /var/lib/libvirt/images/$imagefile

#grep to check loop device
loopdevice=`kpartx -l /var/lib/libvirt/images/$imagefile | cut -d" " -f1 | sed 's/..$//' | sort -u`


echo "Mounting loop device..."
mount "/dev/mapper/"$loopdevice"p1" /mnt/virt

echo "Updating /etc/hostname..."
echo $newhostname > /mnt/virt/etc/hostname

echo "Updating /etc/hosts..."
sed -i "s/debianbase/$newhostname/g" /mnt/virt/etc/hosts

echo "Removing SSH keys..."
rm -rf /mnt/virt/etc/ssh/*host*key*


echo "Copying .xml file..."

cp "/etc/libvirt/qemu/debianbase.xml" "/etc/libvirt/qemu/"$newhostname".xml" 

echo "Setting name to "$newhostname"..."
sed -i 's/>.*<\/name>/>'"$newhostname"'<\/name>/' "/etc/libvirt/qemu/"$newhostname".xml"

echo "Setting new uuid..."
sed -i 's/<uuid>.*<\/uuid>/<uuid>'"$(uuidgen)"'<\/uuid>/' "/etc/libvirt/qemu/"$newhostname".xml"

echo "Setting disk image..."
sed -i 's/<source file='\''.*'\''\/>/<source file='\''\/var\/lib\/libvirt\/images\/'"$imagefile"\''\/>/' "/etc/libvirt/qemu/"$newhostname".xml"

echo "Setting new mac address to: "$newmac
sed -i 's/<mac address='\''.*'\''/<mac address='\'"$newmac"\''/' "/etc/libvirt/qemu/"$newhostname".xml"

#Assign cores if set
if [ $numcores ] 
then
	if [[ $numcores -gt 4 || $numcores -lt 1 ]] 
	then
		echo "Number of cores needs to be between 1 and 4, defaulting to 1..."
	else
		echo "Setting number of CPU cores..."
		sed -i 's/<vcpu placement='\''static'\''>.<\/vcpu>/<vcpu placement='\''static'\''>'"$numcores"'<\/vcpu>/' "/etc/libvirt/qemu/"$newhostname".xml"
	fi
fi


#Assign memory
if [ $memamount ]
then
	echo "Setting memory amount..."
	memamount=$(($memamount*1024))
	sed -i 's/>.*<\/memory>/>'"$memamount"'<\/memory>/' "/etc/libvirt/qemu/"$newhostname".xml"
	sed -i 's/>.*<\/currentMemory>/>'"$memamount"'<\/currentMemory>/' "/etc/libvirt/qemu/"$newhostname".xml"
fi
##else defaults to whatever is in debianbase.xml which is currently 256MB


##Unmount /mnt/virt
echo "Unmounting VM filesystem..."
umount /mnt/virt
dmsetup remove_all
losetup -d /dev/loop*


#Add ip address to dhcpd.conf on netserv.icarus

if [ $staticip ]
then
	#Checks if valid IP format
	if [[ $staticip =~ ^192\.168\.10.[0-9]{1,3}?$ ]] ; then
		lastoctet=`echo $staticip | cut -d. -f4 -`
		
		#Checks if last octet is in range for this network
		if [[ $lastoctet -lt 50 && $lastoctet -gt 0 ]]; then
			echo "Checking IP address..."
			scp root@netserv.icarus:/etc/dhcp/dhcpd.conf /tmp
			
			#Checks if the address is already in use
			if [[ `grep $staticip /tmp/dhcpd.conf` ]]; then
				echo "IP address already in use, defaulting to dynamic address..."
			else	#If not, add it as a static address to dhcpd.conf and push to netserv.icarus
				echo "Adding IP address to dhcpd.conf..."
				ssh root@netserv.icarus 'cp /etc/dhcp/dhcpd.conf{,.bak}'
				sed -i '/marker/ a\\n\thost '"$newhostname"' {\n\t\thardware ethernet '"$newmac"';\n\t\tfixed-address '"$staticip"';\n\t\t}' /tmp/dhcpd.conf
				scp /tmp/dhcpd.conf root@netserv.icarus:/etc/dhcp/dhcpd.conf && ssh root@netserv.icarus 'service isc-dhcp-server restart'
				rm /tmp/dhcpd.conf	
				ipchanged=1
			fi
		else
			echo "The IP address $staticaddress is out of range, defaulting to dynamic address..."
		fi
	else
		echo "The address $static is not a valid, defaulting to dynamic address..."
	fi
fi

#Define VM with virsh
echo "Defining "$newhostname" with virsh..."
virsh --connect qemu:///system define "/etc/libvirt/qemu/"$newhostname".xml"


#Sets VM to autostart on boot, if specified.
if [[ $autostartvm ]]; then
	echo "Creating autostart symbolic link..."
	#ln -s "/etc/libvirt/qemu/"$newhostname".xml" "/etc/libvirt/qemu/autostart/"
	#Better way of doing it:
	virsh --connect qemu:///system autostart $newhostname
fi

#Starts VM now, if specified.
if [[ $startnow ]]; then
	echo "Starting "$newhostname"..."
	virsh --connect qemu:///system start $newhostname
	
	if [ ! $ipchanged ]; then
		echo "Sleeping for 20 seconds to retrieve IP address."
		echo "Feel free to ^c if you don't need the address..."
		sleep 20
		fping -c 1 -g -q 192.168.10.50 192.168.10.100 2> /dev/null
		newip=`arp -an | grep $newmac | cut -d" " -f2 | cut -d"(" -f2 | cut -d")" -f1`
		echo ""
		echo "IP address is: "$newip
	fi
fi
echo ""
echo "Done."
echo ""
