#!/system/bin/sh

idme_device_type_id=`/system/bin/cat /proc/idme/device_type_id`
echo "audio_sys_init: device_type_id: $idme_device_type_id" > /dev/kmsg

if [ $idme_device_type_id == "A3EVMLQTU6WL1W" ] ; then
        /system/bin/setprop vendor.init.svc.bootanim "running"
        #dolby dma hal disable 0: enabled, 1: disabled
        /system/bin/setprop persist.dolby.dma.proxy.disable 0
        #dma continuous output devices (HDMI, BT)
        /system/bin/setprop persist.dolby.dma.devices.cm 1152
        #dma tunnel mode devices (HDMI, BT)
        /system/bin/setprop persist.dolby.dma.devices.tm 1152
        # tunnel mode audio pts adjust
        /system/bin/setprop tunnelmode.raw.apts.adjust -30
        /system/bin/setprop tunnelmode.pcm.apts.adjust -70
        # BT Tunnelmode audio pts adjust
        /system/bin/setprop tunnelmode.bt.apts.adjust 100

        # Audio pts adjust for AV sync fine tuning in non tunnel mode in DMA
        /system/bin/setprop apts_tune.non_tunnel_pcm -50
        /system/bin/setprop apts_tune.non_tunnel_dlb -30
        /system/bin/setprop apts_tune.non_tunnel_bt 0

        # AVLS specific usecase tuning, no impact on regular hdmi playback
        /system/bin/setprop apts_tune.non_tunnel.avls 35
        /system/bin/setprop apts_tune.tunnel.avls -40

	# AVLSU specific usecase tuning, no impact on regular hdmi playback
        /system/bin/setprop apts_tune.non_tunnel.avlsu 35
        /system/bin/setprop apts_tune.tunnel.avlsu -210

else
        echo "audio_sys_init: unknown device_type_id - $idme_device_type_id" > /dev/kmsg
fi

