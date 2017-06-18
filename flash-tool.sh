#!/bin/bash
#----------
target_out=
parts=
skip_uboot=
wipe=
reset=
soc=
linux=
efuse_file=
uboot_file=
dtb_file=
boot_file=
recovery_file=
password=
secured=
destroy=
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[m'
TOOL_PATH="$(cd $(dirname $0); pwd)"

# Helper
# ------
show_help()
{
    echo "Usage      : $0 --target-out=<aosp output directory> --parts=<all|none|logo|recovery|boot|system> [--skip-uboot] [--wipe] [--reset=<y|n>] [--linux] [--soc=<m8|axg|gxl>] [*-file=/path/to/file/location] [--password=/path/to/password.bin]"
    echo "Version    : 3.1"
    echo "Parameters : --target-out   => Specify location path where are all the images to burn or path to aml_upgrade_package.img"
    echo "             --parts        => Specify which partitions to burn"
    echo "             --skip-uboot   => Will not burn uboot"
    echo "             --wipe         => Destroy all partitions"
    echo "             --reset        => Force reset mode at the end of the burning"
    echo "             --soc          => Force soc type (gxl=S905/S912,axg=A113,m8=S805...)"
    echo "             --linux        => Specify the image to flash is linux not android"
    echo "             --efuse-file   => Force efuse OTP burn, use this option carefully "
    echo "             --uboot-file   => Overload default uboot.bin file to be used"
    echo "             --dtb-file     => Overload default dtb.img file to be used"
    echo "             --boot-file    => Overload default boot.img file to be used"
    echo "             --recover-file => Overload default recovery.img file to be used"
    echo "             --password     => Unlock usb mode using password file provided"
    echo "             --destroy      => Erase the bootloader and reset the board"
}

# Check if a given file exists and exit if not
# --------------------------------------------
check_file()
{
    if [[ ! -f $1 ]]; then
        echo "$1 not found"
        cleanup
        exit 1
    fi
}

# Trap called on Ctrl-C
# ---------------------
cleanup()
{
    echo -e $RESET
    [[ -d $tmp_dir ]] && rm -rf "$tmp_dir"
    exit 1
}

# Wrapper for the Amlogic 'update' command
# ----------------------------------------
run_update()
{
    local cmd
    local ret=0

    cmd+="$TOOL_PATH/tools/update 2>/dev/null"
    for arg in "$@"; do
        if [[ "$arg" =~ ' ' ]]; then
            cmd+=" \"$arg\""
        else
            cmd+=" $arg"
        fi
    done

    if `eval $cmd | grep -q "^ERR:"`; then
        [[ "$2" =~ reset|true ]] 
        #|| echo "$cmd: failed"
        ret=1
    fi

    return $ret
}

# Assert update wrapper
# ---------------------
run_update_assert()
{
    run_update "$@"
    if [[ $? != 0 ]]; then
        echo -e $RED"[KO]"
        cleanup
        exit 1
    fi
}

# Parse options
# -------------
for opt do
    optval="${opt#*=}"
    case "${opt%=*}" in
    --help|-h)
        show_help $(basename $0)
        exit 0
        ;;
    --target-out)
        target_out="$optval"
        ;;
    --parts)
        parts="$optval"
        ;;
    --skip-uboot)
        skip_uboot=1
        ;;
    --wipe)
        wipe=1
        ;;
    --reset)
        reset="$optval"
        ;;
    --efuse-file)
        efuse_file="$optval"
        ;;
    --uboot-file)
	uboot_file="$optval"
	;;
    --dtb-file)
        dtb_file="$optval"
        ;;
    --boot-file)
        boot_file="$optval"
        ;;
    --recovery-file)
        recovery_file="$optval"
        ;;
    --soc)
        soc="$optval"
        ;;
    --linux)
        linux=1
        ;;
    --password)
        password="$optval"
        ;;
    --destroy)
        destroy=1
        ;;
    *)
        ;;
    esac
done

# Check parameters
# ----------------
if [[ -z $destroy ]]; then
   if [[ -z $target_out ]]; then
      echo "Missing --target-out argument"
      show_help
      exit 1
   fi

   if [[ ! -d $target_out ]]; then
      if [[ ! -f $target_out ]]; then
         echo "$target_out is not a directory"
         exit 1
      else
         target_img=$target_out
      fi
   fi

   if [[ -z $parts ]]; then
      echo "Missing --parts argument"
      exit 1
   fi
   if [[ "$parts" != "all" ]] && [[ "$parts" != "none" ]] && [[ "$parts" != "logo" ]] && [[ "$parts" != "recovery" ]] && [[ "$parts" != "boot" ]] && [[ "$parts" != "system" ]]; then
      echo "Invalid --parts argument, should be either [all,none,logo,recovery,boot,system]" 
      exit 1
   fi
fi
if [[ -z $soc ]]; then
   soc=gxl
fi
if [[ "$soc" != "gxl" ]] && [[ "$soc" != "axg" ]] && [[ "$soc" != "m8" ]]; then
   echo "Soc type is invalid, should be either gxl,axg,m8"
   exit 1
fi
if ! `$TOOL_PATH/tools/update identify 7 | grep -iq firmware`; then
   echo "Amlogic device not found"
   exit 1
fi

trap cleanup SIGHUP SIGINT SIGTERM

# Check if the board is locked with a password
# --------------------------------------------
need_password=0
if `$TOOL_PATH/tools/update identify 7 | grep -iq "Password check NG"`; then
   need_password=1
fi
if [[ $need_password == 1 ]]; then
   if [[ -z $password ]]; then
     echo "The board is locked with a password, please provide a password using --password option !"
     exit 1
   fi
fi

# Unlock usb mode by password
# ---------------------------
if [[ $need_password == 1 ]]; then
   if [[ $password != "" ]]; then
      echo -n "Unlocking usb interface "
      run_update_assert password $password
      if `$TOOL_PATH/tools/update identify 7 | grep -iq "Password check OK"`; then
         echo -e $GREEN"[OK]"$RESET
      else
         echo -e $RED"[KO]"$RESET
         echo "It seems you provided an incorrect password !"
         exit 1
      fi
   fi
fi

# Create tmp directory
# --------------------
tmp_dir=$(mktemp -d /tmp/aml-flash-tool-XXXX)

# Should we destroy the boot ?
# ----------------------------
if [[ -z $skip_uboot ]]; then
   run_update tplcmd "echo 12345"
   run_update bulkcmd "low_power"
   if [[ $? = 0 ]]; then
      echo -n "Rebooting the board "
      run_update bulkcmd "bootloader_is_old"
      run_update_assert bulkcmd "erase_bootloader"
      run_update_assert bulkcmd "store erase boot"
      run_update bulkcmd "reset"
      if [[ $destroy == 1 ]]; then
        echo -e $GREEN"[OK]"$RESET
        exit 0
      fi
      for i in {1..8}
         do
         echo -n "."
         sleep 1
      done
      echo -e $GREEN"[OK]"$RESET
   else
     if [[ $destroy == 1 ]]; then
        echo "Seems board is already in usb mode, nothing to do more..."
        exit 0
     fi
   fi
fi
if [[ $destroy == 1 ]]; then
   exit 0
fi

# Unlock usb mode by password
# ---------------------------
# If we started with usb mode from uboot, the password is already unlocked
# But just after we reset the board, then fall into rom mode
# That's why we need to recheck password lock a second time
need_password=0
if `$TOOL_PATH/tools/update identify 7 | grep -iq "Password check NG"`; then
   need_password=1
fi
if [[ $need_password == 1 ]]; then
   if [[ -z $password ]]; then
     echo "The board is locked with a password, please provide a password using --password option !"
     exit 1
   fi
fi
if [[ $need_password == 1 ]]; then
   if [[ $password != "" ]]; then
      echo -n "Unlocking usb interface "
      run_update_assert password $password
      if `$TOOL_PATH/tools/update identify 7 | grep -iq "Password check OK"`; then
         echo -e $GREEN"[OK]"$RESET
      else
         echo -e $RED"[KO]"$RESET
         echo "It seems you provided an incorrect password !"
         exit 1
      fi
   fi
fi

# Read chip id
# ------------
#if [[ "$soc" == "auto" ]]; then
#  echo -n "Identify chipset type "
#  value=`$TOOL_PATH/tools/update chipid|grep ChipID|cut -d ':' -f2|xxd -r -p|cut -c1-6`
#  echo $value
#  if [[ "$value" == "AMLGXL" ]]; then
#     soc=gxl
#  fi
#  if [[ "$value" == "AMLAXG" ]]; then
#     soc=axg
#  fi
#  if [[ "$soc" != "gxl" ]] && [[ "$soc" != "axg" ]] && [[ "$soc" != "m8" ]]; then
#     echo -e $RED"[KO]"$RESET
#     echo "Unable to identify chipset, Try by forcing it manually with --soc=<gxl,axg,m8>"
#     exit 1
#  else
#     echo -e $GREEN"["$value"]"$RESET
#  fi
#fi

# Check if board is secure
# ------------------------
secured=0
value=0
if [[ "$soc" == "gxl" ]]; then
   value=$((0x`$TOOL_PATH/tools/update 2>/dev/null rreg 4 0xc8100228|grep C8100228|cut -d' ' -f 2` & 0x10))
fi
if [[ "$soc" == "axg" ]]; then
   value=$((0x`$TOOL_PATH/tools/update 2>/dev/null rreg 4 0xff800228|grep FF800228|cut -d' ' -f 2` & 0x10))
fi
if [[ $value != 0 ]]; then
   secured=1
   echo "Board is in secure mode"
fi

# Unpack image if image is given
# ------------------------------
if [ ! -z "$target_img" ]; then
   $TOOL_PATH/tools/aml_image_v2_packer -d $target_img $tmp_dir &>/dev/null
   target_out=$tmp_dir
   find $tmp_dir -name '*.PARTITION' -exec sh -c 'mv "$1" "${1%.PARTITION}.img"' _ {} \;
   if [[ $soc == "gxl" ]] || [[ $soc == "axg" ]]; then
      mv $tmp_dir/_aml_dtb.img  $tmp_dir/dtb.img
      mv $tmp_dir/UBOOT.USB     $tmp_dir/u-boot.bin.usb.tpl
      mv $tmp_dir/DDR.USB       $tmp_dir/u-boot.bin.usb.bl2
      mv $tmp_dir/UBOOT_ENC.USB $tmp_dir/u-boot.bin.encrypt.usb.tpl &>/dev/null
      mv $tmp_dir/DDR_ENC.USB   $tmp_dir/u-boot.bin.encrypt.usb.bl2 &>/dev/null
   fi
   if [[ $soc == "m8" ]]; then
      mv $tmp_dir/meson.dtb $tmp_dir/dt.img
      mv $tmp_dir/UBOOT_COMP.USB $tmp_dir/u-boot-comp.bin
      mv $tmp_dir/DDR.USB $tmp_dir/ddr_init.bin
   fi
   mv $tmp_dir/bootloader.img $tmp_dir/u-boot.bin
   if [[ $linux = 1 ]]; then
      mv $tmp_dir/system.img $tmp_dir/rootfs.ext2.img2simg
   fi
fi

# Uboot update 
# ------------
if [[ -z $skip_uboot ]]; then
   if [[ $soc == "gxl" ]] || [[ $soc == "axg" ]]; then
      ddr=$TOOL_PATH/tools/usbbl2runpara_ddrinit.bin
      fip=$TOOL_PATH/tools/usbbl2runpara_runfipimg.bin
   fi
   if [[ $soc == "m8" ]]; then
      ddr=$target_out/ddr_init.bin
      fip=$TOOL_PATH/tools/decompressPara_4M.dump
   fi
   if [[ -z "$uboot_file" ]]; then
      uboot_file=$target_out/u-boot.bin
   fi
   uboot=$uboot_file
   if [[ -z "$dtb_file" ]]; then
      if [[ $soc == "gxl" ]] || [[ $soc == "axg" ]]; then
         dtb=$target_out/dtb.img
      fi
      if [[ $soc == "m8" ]]; then
         dtb=$target_out/dt.img
      fi
   else
      dtb=$dtb_file
   fi

   check_file "$uboot"
   check_file "$dtb"
   check_file "$ddr"
   check_file "$fip"

   if [[ $soc == "gxl" ]] || [[ $soc == "axg" ]]; then
      if [[ $secured == 0 ]]; then
         bl2=$target_out/u-boot.bin.usb.bl2
         tpl=$target_out/u-boot.bin.usb.tpl
      else
         bl2=$target_out/u-boot.bin.encrypt.usb.bl2
         tpl=$target_out/u-boot.bin.encrypt.usb.tpl
      fi
      check_file "$bl2"
      check_file "$tpl"
   fi
   if [[ $soc == "m8" ]]; then
      check_file "$target_out/u-boot-comp.bin"
      tpl=$target_out/u-boot-comp.bin
   fi
   echo -n "Initializing ddr "
   if [[ $soc == "gxl" ]]; then
      run_update_assert cwr   "$bl2" 0xd9000000
      run_update_assert write "$ddr" 0xd900c000
      run_update_assert run          0xd9000000
   fi
   if [[ $soc == "axg" ]]; then
      run_update_assert cwr   "$bl2" 0xfffc0000
      run_update_assert write "$ddr" 0xfffcc000
      run_update_assert run          0xfffc0000
   fi
   if [[ $soc == "m8" ]]; then
      run_update_assert cwr "$ddr"   0xd9000000
      run_update_assert run          0xd9000030
   fi
   for i in {1..8}
   do
       echo -n "."
       sleep 1
   done
   echo -e $GREEN"[OK]"$RESET

   echo -n "Running u-boot "
   if [[ $soc == "gxl" ]]; then
      run_update_assert write "$bl2" 0xd9000000
      run_update_assert write "$fip" 0xd900c000 # tell bl2 to jump to tpl, aka u-boot
      run_update_assert write "$tpl" 0x0200c000
      run_update_assert run          0xd9000000
   fi
   if [[ $soc == "axg" ]]; then
      run_update_assert write "$bl2" 0xfffc0000
      run_update_assert write "$fip" 0xfffcc000 # tell bl2 to jump to tpl, aka u-boot
      run_update_assert write "$tpl" 0x0200c000
      run_update_assert run          0xfffc0000
   fi
   if [[ $soc == "m8" ]]; then
      run_update_assert write "$fip" 0xd9010000
      run_update_assert write "$tpl" 0x00400000
      run_update_assert run          0xd9000030
      run_update_assert run          0x10000000
   fi
   for i in {1..8}
   do
       echo -n "."
       sleep 1
   done
   echo -e $GREEN"[OK]"$RESET

   run_update bulkcmd "low_power"

   if [[ $soc == "gxl" ]] || [[ $soc == "axg" ]]; then
      if [[ $secured == 1 ]]; then
         check_file "$target_out/meson1.dtb"
      fi
      echo -n "Writing device tree "
      if [[ $secured == 1 ]]; then
         run_update_assert mwrite "$target_out/meson1.dtb" mem dtb normal
      else
         # We could be in the case that $dtb is signed but the board is not yet secure
         # So need to load non secure dtb here in all cases
         headstring=`head -c 4 $dtb`
         if [[ $headstring == "@AML" ]]; then
            check_file "$target_out/meson1.dtb"
            run_update_assert mwrite "$target_out/meson1.dtb" mem dtb normal
         else
            run_update_assert mwrite "$dtb" mem dtb normal
         fi
      fi
      echo -e $GREEN"[OK]"$RESET

      echo -n "Create partitions "
      if [[ $wipe == 1 ]]; then
         run_update_assert bulkcmd "disk_initial 1"
      else
         run_update_assert bulkcmd "disk_initial 0"
      fi
      run_update_assert partition _aml_dtb "$dtb"
      echo -e $GREEN"[OK]"$RESET

      echo -n "Writing u-boot "
      run_update_assert partition bootloader "$uboot"
      run_update_assert bulkcmd "env default -a"
      run_update_assert bulkcmd "saveenv"
      echo -e $GREEN"[OK]"$RESET
   else
      echo -n "Creating partitions "
      if [[ $wipe == 1 ]]; then
         run_update_assert bulkcmd "disk_initial 3"
      else
         run_update_assert bulkcmd "disk_initial 0"
      fi
      echo -e $GREEN"[OK]"$RESET

      echo -n "Writing u-boot "
      run_update_assert partition bootloader "$uboot"
      echo -e $GREEN"[OK]"$RESET

      echo -n "Writing device tree "
      run_update_assert mwrite "$dtb" mem dtb normal
      echo -e $GREEN"[OK]"$RESET
   fi
fi

# Recovery partition update
# -------------------------
if [[ "$parts" =~ all|recovery ]] && [[ $linux != 1 ]]; then
    if [[ -z "$recovery_file" ]]; then
        recovery_file=$target_out/recovery.img
    fi
    recovery=$recovery_file
    check_file "$recovery"

    echo -n "Writing recovery image "
    run_update_assert partition recovery "$recovery"
    echo -e $GREEN"[OK]"$RESET
fi

# Boot partition update
# ---------------------
if [[ "$parts" =~ all|boot ]]; then
    if [[ -z "$boot_file" ]]; then
        boot_file=$target_out/boot.img
    fi
    boot=$boot_file
    check_file "$boot"

    echo -n "Writing boot image "
    run_update_assert partition boot "$boot"
    echo -e $GREEN"[OK]"$RESET
fi

# System partition update
# -----------------------
if [[ "$parts" =~ all|system ]]; then
    if [[ $linux = 1 ]]; then
      system=$target_out/rootfs.ext2.img2simg
    else
      system=$target_out/system.img
    fi
    check_file "$system"

    echo -n "Writing system image "
    if [[ $soc == "axg" ]]; then
       run_update_assert partition system "$system" ubifs
    else
       run_update_assert partition system "$system"
    fi
    echo -e $GREEN"[OK]"$RESET
fi

# Logo partition update
# ---------------------
if [[ "$parts" =~ all|logo ]]; then
    logo=$target_out/logo.img
    if [[ -f $logo ]]; then
        echo -n "Writing logo image "
        if [[ $soc == "axg" ]]; then
           run_update_assert partition logo "$logo" ubifs
        else
           run_update_assert partition logo "$logo"
        fi
        echo -e $GREEN"[OK]"$RESET
    fi
fi

# Data and cache partitions wiping
# --------------------------------
if [[ $soc != "m8" ]] && [[ $linux != 1 ]]; then
    if [[ $wipe = 1 ]]; then
        echo -n "Wiping data partition "
        run_update_assert bulkcmd "amlmmc erase data"
        echo -e $GREEN"[OK]"$RESET
	
        echo -n "Wiping cache partition "
        run_update_assert bulkcmd "amlmmc erase cache"
        echo -e $GREEN"[OK]"$RESET

	echo -n "Writing cache image "
	cache=$target_out/cache.img
        if [[ ! -f $cache ]]; then
	  echo -e $YELLOW"[SKIP]"$RESET
        else
          run_update_assert partition cache "$cache"
          echo -e $GREEN"[OK]"$RESET
	fi
    fi
fi

# Terminate burning tool
# ----------------------
echo -n "Terminate update of the board "
run_update_assert bulkcmd save_setting
echo -e $GREEN"[OK]"$RESET

# eFuse update
# ------------
if [[ $efuse_file != "" ]]; then
   check_file "$efuse_file"
   echo -n "Programming efuses "
   run_update_assert write $efuse_file 0x03000000
   run_update_assert bulkcmd "efuse amlogic_set 0x03000000"
   echo -e $GREEN"[OK]"$RESET
   run_update bulkcmd "low_power"
fi

# Cleanup
# -------
[[ -d $tmp_dir ]] && rm -rf "$tmp_dir"

# Resetting board ? 
# -----------------
if [[ -z "$reset" ]]; then
    while true; do
        read -p "Do you want to reset the board? y/n [n]? " reset
        if [[ $reset =~ [yYnN] ]]; then
            break
        fi
    done
fi
if [[ $reset =~ [yY] ]]; then
    echo -n "Resetting board "
    run_update bulkcmd "burn_complete 1"
    echo -e $GREEN"[OK]"$RESET
fi
