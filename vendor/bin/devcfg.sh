#!/vendor/bin/sh

idme_device_type_id=`/vendor/bin/cat /proc/idme/device_type_id`
echo "devcfg: device_type_id: $idme_device_type_id" > /dev/kmsg

#Kara
if [ $idme_device_type_id == "A3EVMLQTU6WL1W" ]; then
        /vendor/bin/setprop ro.vendor.nrdp.modelgroup FIRETVSTICK2021
        /vendor/bin/setprop ro.vendor.nrdp.validation ninja_8
else
        echo "devcfg: unknown device_type_id - $idme_device_type_id" > /dev/kmsg
fi

