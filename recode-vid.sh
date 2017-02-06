#!/bin/sh

usage() {
    PROG="$1"
    echo "USAGE: $PROG [opts] in out
    or: $PROG [opts] -id in [out]
    opts:
	-ac	X	use audio codec X
	-af	F	append audio filter F
	-afpre	F	prepend audio filter F
	-aid	X	audio stream selector
	-alang	L	set audio stream language L
	-arate	R	set audio rate R
	-asd	S	set asyncts min_delta to S
	-h	H	scale to height H
	-id		print info on audio/subs IDs
	-n		don't overwrite output file
	-noass		don't use \"ass\" filter for subs
	-sdir	D	external subtitles subdirectory
	-sid	N	select Nth subtitles stream
	-subcp	X	assume codepage X for input subtitles
	-subss	X	force subs style X (e.g. Fontstyle=40)
	-tvol	T	set volume threshold at T dB
	-vf	F	append video filter F
	-vfpre	F	prepend video filter F
	-vid	N	select Nth video stream
	-vol	A	increase volume by A dB
	-w	W	scale to width W
	-y		overwrite output file (default)"
    exit 1
}

# check file for utf8 encoding: 0-utf8 1-other
check_fileencoding() {
    perl -ws -- - "$1" "$2" <<EOF
	use Encode qw(encode decode);
	my (\$fn, \$enc, \$thresh) = @ARGV;
	die "check_fileencoding: filename is required\\n"
	    if not defined \$fn;
	my \$bom;
	\$enc = "utf8" if not defined \$enc;
	\$thresh = 0.01 if not defined \$thresh;
	open my \$fh, "<", \$fn or die \$!;
	my (\$bad, \$total) = (0, 0);
	while (<\$fh>) {
	    if (\$total == 0 and \$enc =~ /\\Autf-?8\\z/i) {
		my \$b2 = substr(\$_, 0, 2);
		if (\$b2 eq "\\xff\\xfe") {
		    \$bom = "utf16le BOM \\"fffe\\" detected";
		} elsif (\$b2 eq "\\xfe\\xff") {
		    \$bom = "utf16be BOM \\"feff\\" detected";
		};
	    };
	    \$total += length(\$_);
	    decode(\$enc, \$_, sub {\$bad++; return "\\x{FFFD}"});
	};
	close \$fh;
	if (defined \$bom) {
	    printf "%s: %s\\n", \$fn, \$bom;
	    exit 1;
	};
	if (\$bad / \$total < \$thresh) {
	    if (\$bad) {
		printf "%s: %i bad char%s (%.2f%%), assuming %s\\n",
		    \$fn, \$bad, ((\$bad > 1) ? "s" : ""),
		    \$bad * 100 / \$total, \$enc;
	    };
	    exit 0;
	} else {
	    exit 1;
	};
EOF
    return $?
}

SCRIPT_BNAME="${0##*/}"
SCRIPT_BNAME_S="`perl -wsle \
   '$ARGV[0] =~ s/[^A-Za-z0-9_.-]/_/g; print $ARGV[0]' \
   -- "$SCRIPT_BNAME"`"
TMPF="/tmp/${SCRIPT_BNAME_S}.$$"
TMP_OUT="${TMPF}.out"
TMP_PASS=""	; # temporary file for 2- or 3-pass encoding
TMP_SUBS=""	; # temporary file or symlink for subtitles

die() {
    rm -f "${TMPF}".*
    E=1
    if [ 0 -lt $# ] && expr "z$1" : 'z[0-9][0-9]*$' >/dev/null ; then
	E="$1"
	shift
    fi
    if [ 0 -lt $# ] ; then
	echo "ERROR:" "$@" 1>&2
    fi
    exit "$E"
}

eint() {
    rm -f "${TMPF}".*
    # revert to default INT handler and resend INT to self:
    trap - INT
    kill -INT $$
}
trap eint INT

# video/subtitles params:
VID="0:v:0"
SID=""
SUBCP=""	; # subtitles codepage
SUBSD=""	; # external subtitles subdirectory
SUBSS=""	; # forced subtitles style
SUBS_FILTER=""	; # "ass" "or subtitles"
VF_SUBS=""	; # "subtitles"/"ass" video filter with params
VF_SCALE=",scale=w=720:h=ceil(ih*ow/iw/sar/2)*2,setsar=sar=1"
VF_OTHER=""	; # other video filters to append
VFPRE_OTHER=""	; # other video filters to prepend
# audio params:
AID=""		; # audio stream id
AIDX=""		; # audio stream selector expression
AC="libvorbis"	; # audio codec
ARATE=""
ASD="0.3"	; # asyncts min_delta [0.3s]. You need to increase it
		  # if you get messages like "[Parsed_asyncts_0 @
		  # 0x1719be0] Non-monotonous timestamps, dropping
		  # whole buffer." XXX
ALANG=""	; # output audio language tag
ADD_VOL=""	; # additional audio volume
THRESH_VOL="-0.5" ; # volume threshold for autoincrease
AF_VOL=""	; # "volume" audio filter
AF_OTHER=""	; # other audio filters to append
AFPRE_OTHER=""	; # other audio filters to prepend
# other params:
ID_MODE=""	; # "identify AIDs/SIDs" mode (-id)
OVWR_OUT="-y"	; # "overwrite output file" option
ARG_CNT=0	; # arguments counter
CUR_OPT="none"	; # current option
# in/out/tail argument groups:
GRPC=0		; # argument groups counter
ARGC=0		; # group arguments counter
INC=0		; # input groups counter
OUTC=0		; # output groups counter
TGRPN=""	; # tail group number
# video/audio/subs streams:
VIDC=0		; # video streams counter
AIDC=0		; # audio streams counter
SUBC=0		; # subtitles streams counter

incr() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    eval "$1=\"\`expr 1 + \"\$$1\"\`\""
}

next_grp() {
    eval "G${GRPC}TYP=\"\$1\""
    eval "G${GRPC}ARGC=\"\$ARGC\""
    incr GRPC
    ARGC=0
}

add_in_file() {
    fname="$1"
    bname="${fname##*/}"
    dir="${fname%/*}"
    if [ "z$dir" = "z$fname" ] ; then
	dir="."
    fi
    dir="$dir/"
    if ! [ -e "$fname" ] ; then
	die "$fname doesn't exist"
    fi
    if ! [ -f "$fname" ] && ! [ -l "$fname" ] ; then
	die "$fname isn't a file or symlink"
    fi
    if ! [ -d "$dir" ] ; then
	die "$dir isn't a dir"
    fi
    eval "IN${INC}GRP=\"\$GRPC\""
    eval "IN${INC}=\"\$fname\""
    eval "IN${INC}BNAME=\"\$bname\""
    eval "IN${INC}DIR=\"\$dir\""
    next_grp "IN${INC}"
    incr INC
    TGRPN=""
}

add_out_file() {
    case "$1" in
	*/)
	    if [ "z$INC" = "z0" ] ; then
		die "at least one input file name required"\
		    "to generate output file name in $1"
	    fi
	    last_in="`expr \( "$INC" \) - 1`"
	    eval "in_bname=\"\$IN{$last_in}BNAME\""
	    # XXX: assume matroska (.mkv) format for the output file:
	    fname="$1${in_bname%.*}.mkv"
	    ;;
	*)  fname="$1" ;;
    esac
    dir="${fname%/*}"
    if [ "z$dir" = "z$fname" ] ; then
	dir="."
    fi
    dir="$dir/"
    if ! [ -d "$dir" ] ; then
	die "$dir isn't a dir"
    fi
    eval "OUT${OUTC}GRP=\"\$GRPC\""
    eval "OUT${OUTC}=\"\$fname\""
    next_grp "OUT${OUTC}"
    incr OUTC
    TGRPN=""
}

append_grp2cmd() {
    if ! expr "z$1" : 'z[0-9][0-9]*$' >/dev/null ; then
	die "invalid group number - $1"
    fi
    if ! expr "z$2" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $2"
    fi
    eval "agrpargc=\"\$G${1}ARGC\""
    aj=0
    while [ "$aj" -lt "$agrpargc" ] ; do
	eval "$2=\"\$$2 \\\"\\\$G${1}A$aj\\\"\""
	incr aj
    done
    if [ "z$3" = "zfull" ] ; then
	eval "agrptyp=\"\$G${1}TYP\""
	case "$agrptyp" in
	    IN*)  eval "$2=\"\$$2 -i \\\"\\\$$agrptyp\\\"\"" ;;
	    OUT*) eval "$2=\"\$$2 \\\"\\\$$agrptyp\\\"\"" ;;
	esac
    fi
}

# parse_stream_id AID 0:1
parse_stream_id() {
    if ! expr "z$1" : 'z[A-Za-z_][A-Za-z_0-9]*$' >/dev/null ; then
	die "invalid variable name - $1"
    fi
    fre='\([0-9][0-9]*:\)\{0,1\}'		; # optional file id
    hre='\([0-9][0-9]*\|0x[0-9a-fA-F]\{1,\}\)'	; # dec/hex
    wre='[A-Za-z_][A-Za-z_0-9]*'		; # word
    if [ "z$A" = "znone" ] ; then
	eval "$1=\"\$2\""
    elif expr "z$A" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
    >/dev/null ; then
	# 0:0
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[avs]\\(:[0-9][0-9]*\\)\\{0,1\\}\$" \
    >/dev/null ; then
	# 1:v:1, a:2, 2:s, a
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[p]\\(:[0-9][0-9]*\\)\\{1,2\\}\$" \
    >/dev/null ; then
	# 3:p:1:3, p:2:4, 4:p:3, p:4
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre\\(#\\|i:\\):$hre\$" \
    >/dev/null ; then
	# #0x1100, i:0x1101, #231, i:232, 5:#0x1102, 6:i:0x1103,
	# 7:#234, 8:i:235
	eval "$1=\"\$2\""
    elif expr "z$A" : "z$fre[m]:$wre\\(:.*\\)\\{0,1\\}\$" \
    >/dev/null ; then
	# m:LANGUAGE:jpn, 9:m:LANGUAGE:rus, m:ENCODER, 10:m:ENCODER
	eval "$1=\"\$2\""
    else
	# 5:rus!default
	eval "${1}X=\"\$2\""
    fi
}

parse_args() {
    while [ 0 -lt $# ] ; do
	A="$1"
	shift
	case "$CUR_OPT" in
	    -ac)
		AC="$A"
		CUR_OPT="none"
		;;
	    -af)
		AF_OTHER="$AF_OTHER,$A"
		CUR_OPT="none"
		;;
	    -afpre)
		AFPRE_OTHER="$AFPRE_OTHER$A,"
		CUR_OPT="none"
		;;
	    -aid)
		parse_stream_id AID "$A"
		CUR_OPT="none"
		;;
	    -alang)
		ALANG="$A"
		CUR_OPT="none"
		;;
	    -arate)
		ARATE="$A:"
		CUR_OPT="none"
		;;
	    -asd)
		ASD="$A"
		CUR_OPT="none"
		;;
	    -h)
		VF_SCALE=",scale=h=$A:w=ceil(iw*oh/ih/sar/2)*2,setsar=sar=1"
		CUR_OPT="none"
		;;
	    -sid)
		SID="$A"
		CUR_OPT="none"
		;;
	    -subcp)
		SUBCP="$A"
		CUR_OPT="none"
		;;
	    -subsd|-sdir)
		SUBSD="$A"
		CUR_OPT="none"
		;;
	    -subss)
		SUBSS="$A"
		CUR_OPT="none"
		;;
	    -tvol)
		THRESH_VOL="$A"
		CUR_OPT="none"
		;;
	    -vf)
		VF_OTHER="$VF_OTHER,$A"
		CUR_OPT="none"
		;;
	    -vfpre)
		VFPRE_OTHER="$VFPRE_OTHER,$A"
		CUR_OPT="none"
		;;
	    -vid)
		case "$A" in
		    *:v:*|*:\#*:*|none) VID="$A" ;;
		    *:*:*) die "invalid -vid $A" ;;
		    \#*:*) VID="0:$A" ;;
		    *) VID="0:v:$A" ;;
		esac
		CUR_OPT="none"
		;;
	    -vol)
		ADD_VOL="$A"
		CUR_OPT="none"
		;;
	    -w)
		VF_SCALE=",scale=w=$A:h=ceil(ih*ow/iw/sar/2)*2,setsar=sar=1"
		CUR_OPT="none"
		;;
	    -*)
		case "$CUR_OPT" in
		    -b:v)
			# use 2pass encoding when desired
			# bitrate is known
			TMP_PASS="${TMPF}.pass"
			;;
		    -crf)
			# don't use 2pass encoding with -crf
			TMP_PASS=""
			;;
		esac
		case "$CUR_OPT" in
		    -i) add_in_file "$A" ;;
		    *)  eval "G${GRPC}A${ARGC}=\"\$CUR_OPT\""
			incr ARGC
			eval "G${GRPC}A${ARGC}=\"\$A\""
			incr ARGC
			;;
		esac
		CUR_OPT="none"
		;;
	    none)
		case "$A" in
		    -id)
			ID_MODE="1"
			;;
		    -n) OVWR_OUT="-n" ;;
		    -noass)
			SUBS_FILTER="subtitles"
			;;
		    -y) OVWR_OUT="-y" ;;
		    -*)
			CUR_OPT="$A"
			;;
		    *)
			CUR_OPT="none"
			case $ARG_CNT in
			    0)
				add_in_file "$A"
				ARG_CNT="1"
				;;
			    1)
				add_out_file "$A"
				ARG_CNT="2"
				;;
			    *)
				usage "${0##*/}"
				;;
			esac
			;;
		esac
		;;
	esac
    done
    if [ "z$ARGC" != "z0" ] ; then
	TGRPN="$GRPC"
	next_grp "tail"
    fi
    if [ "z$ID_MODE" = "z1" ] ; then
	if [ "z$IN0" = "" ] ; then
	    usage "${0##*/}"
	fi
    else
	if [ "z$ARG_CNT" != "z2" ] ; then
	    usage "${0##*/}"
	fi
    fi
}

if ! [ -x /usr/bin/bc ] ; then
    die "/usr/bin/bc not found"
fi
parse_args "$@"

# Read data with leading whitespace:
readw() {
    readw_ifs0="$IFS"
    IFS="
"
    read "$@"
    readw_ret="$?"
    IFS="$readw_ifs0"
    return "$readw_ret"
}

# Match stream vs selector:
match() {
    match="$2"
    matchtype=':'
    while [ "z$match" != "z" ] ; do
	matchtail="${match#*[:!]}"
	matchhead="${match%%[:!]*}"
	if [ "z$matchhead" != "z" ] ; then
	    if expr "z$matchhead" : 'z[0-9][0-9]*$' >/dev/null ; then
		matchno="$matchhead"
	    else
		case "$1" in
		    *"$matchhead"*) matchres=':';;
		    *) matchres='!';;
		esac
		if [ "z$matchres" != "z$matchtype" ] ; then
		    return 1
		fi
	    fi
	fi
	# set type of match for the next iteration:
	if [ "z$matchhead" = "z${match%%!*}" ] ; then
	    matchtype='!'
	else
	    matchtype=':'
	fi
	if [ "z$matchtail" = "z$match" ] ; then
	    match=""
	else
	    match="$matchtail"
	fi
    done
    return 0
}

# Detect internal video/audio/subtitles stream IDs:
if ( [ "z$AID" = "z" ] && \
    ( [ "z$AIDX" != "z" ] || [ "z$ALANG" != "z" ] ) ) \
|| [ "z$SID" != "znone" ] ; then
    ffmpeg="ffmpeg -hide_banner"
    i=0
    while [ "$i" -lt "$INC" ] ; do
	ffmpeg="$ffmpeg -i \"\$IN$i\""
	incr i
    done
    echo "$ffmpeg"
    eval "echo $ffmpeg"
    eval "$ffmpeg >\"\$TMP_OUT\" 2>&1"
    state=""
    while readw L ; do
	# Stream #0:1(rus): Audio: aac (HE-AAC), 44100 Hz, 5.1,
	# fltp (default)
	#
	# Stream #0:1[0x1100]: Audio: pcm_bluray (HDMV / 0x564D4448),
	# 48000 Hz, stereo, s16, 1536 kb/s
	#
	# Stream #0:1: Audio: mp3 (U[0][0][0] / 0x0055), 48000 Hz,
	# stereo, s16p, 160 kb/s
	# Metadata:
	#   title           : Suzaku
	case "$L" in
	    \ \ \ \ Stream\ \#*:\ Video:\ *) state="Video";;
	    \ \ \ \ Stream\ \#*:\ Audio:\ *) state="Audio";;
	    \ \ \ \ Stream\ \#*:\ Subtitles:\ *) state="Subtitles";;
	    \ \ \ \ Metadata:)
		if ! expr "z$state" : 'z[AVS]ID[0-9][0-9]*DESC$' \
		    >/dev/null ; then
		    state="meta"
		fi
		;;
	    \ \ \ \ \ \ ????????????????:\ *)
		if expr "z$state" : 'z[AVS]ID[0-9][0-9]*DESC$' \
		    >/dev/null ; then
		    key="${L%%:*}"
		    val="${L#*: }"
		    i=0
		    while [ "$i" -lt 22 ] ; do
			key="${key% }"
			key="${key# }"
			incr i
		    done
		    eval "$state=\"\$$state, \$key:\$val\""
		fi
		;;
	    *)  state="";;
	esac
	case "$state" in
	    Video|Audio|Subtitles)
		desc="${L#    Stream #}"
		id0="${desc%%: $state: *}"
		desc="${desc#*: $state: }"
		id="${id0%%(*}"
		id="${id%%\[*}"
		if ! expr "z$id" : 'z[0-9][0-9]*:[0-9][0-9]*$' \
			>/dev/null ; then
		    die "invalid stream id: $L"
		fi
		eval "bname=\"\$IN${id%:*}BNAME\""
		;;
	esac
	case "$state" in
	    Video)
		eval "VID$VIDC=\"\$id\""
		eval "VID${VIDC}DESC=\"\$bname, int.stream#\$id0," \
		    "\$desc\""
		case "$desc" in *\ \(default\)) VIDDEF="$VIDC" ;; esac
		state="VID${VIDC}DESC"
		incr VIDC
		;;
	    Audio)
		eval "AID$AIDC=\"\$id\""
		eval "AID${AIDC}DESC=\"\$bname, int.stream#\$id0," \
		    "\$desc\""
		case "$desc" in *\ \(default\)) AIDDEF="$AIDC" ;; esac
		state="AID${AIDC}DESC"
		incr AIDC
		;;
	    Subtitles)
		eval "SID$SIDC=\"\$id\""
		eval "SID${SIDC}DESC=\"\$bname, int.stream#\$id0," \
		    "\$desc\""
		case "$desc" in *\ \(default\)) SIDDEF="$SIDC" ;; esac
		state="SID${SIDC}DESC"
		incr SIDC
		;;
	esac
    done <"$TMP_OUT"
fi

# Find external audio streams:
i=0
inxc="$INC"	; # input + ext files counter
while [ "$i" -lt "$INC" ] ; do
    eval "ibname=\"\$IN${i}BNAME\""
    eval "idir=\"\$IN${i}DIR\""
    # Create search pattern for find ... -name ... Note: when the
    # old-style `` substitution is used, \$, \` and \\ sequences _are_
    # expanded before subshell is forked to execute the command:
    find_prefix="`perl -wse \
	'$ARGV[0] =~ s/([]*?[])/\\\\$1/g; print $ARGV[0]' \
	-- "${ibname%.*}"`"
    if [ "z$ADIR" != "z" ] ; then
	adir="$ADIR"
    else
	adir="$idir"
    fi
    # Look for .flac, .mka, .mp3 & .ogg files:
    find "$adir" -name "$find_prefix*.flac" \
	-o -name "$find_prefix*.FLAC" \
	-o -name "$find_prefix*.mka" \
	-o -name "$find_prefix*.MKA" \
	-o -name "$find_prefix*.mp3" \
	-o -name "$find_prefix*.MP3" \
	-o -name "$find_prefix*.ogg" \
	-o -name "$find_prefix*.OGG" | sort >"$TMP_OUT"
    while read f ; do
	if [ -f "$f" ] || [ -h "$f" ] ; then
	    # store audio file info in AIDxx/AIDxxDESC variables:
	    eval "AID$AIDC=\"\$inxc:0\""
	    eval "AID${AIDC}DESC=\"\$f, ext.stream#\$inxc:0\""
	    eval "AID${AIDC}EXTF=\"\$f\""
	    incr AIDC
	    incr inxc
	fi
    done <"$TMP_OUT"
    incr i
done

# Find AID by AIDX/ALANG:
if [ "z$AIDX" != "z" ] ; then
    aidx="$AIDX"
elif [ "z$ALANG" != "z" ] ; then
    aidx="($ALANG)"
else
    aidx=""
fi
if ( [ "z$AID" = "z" ] && [ "z$aidx" != "z" ] ) \
    || [ "z$ID_MODE" = "z1" ] ; then
    i=0
    aidm=""	; # matching aid
    aidmc=0	; # count of matching aids
    while [ "$i" -lt "$AIDC" ] ; do
	eval "desc=\"\$AID${i}DESC\""
	if match "$desc" "$aidx" ; then
	    eval "aidm$aidmc=$i"
	    incr aidmc
	fi
	incr i
    done
    if [ 0 -lt "$aidmc" ] ; then
	if [ "z$matchno" = "z" ] ; then
	    matchno=0
	fi
	if [ "$matchno" -lt 0 ] ; then
	    matchno="`expr "$aidmc" + "$matchno"`"
	fi
	if [ 0 -le "$matchno" ] && [ "$matchno" -lt "$aidmc" ] ; then
	    eval "aidm=\"\$aidm$matchno\""
	fi
    fi
    i=0
    while [ "$i" -lt "$AIDC" ] ; do
	eval "desc=\"\$AID${i}DESC\""
	eval "id=\"\$AID$i\""
	mark=""
	if [ "z$AID" = "z" ] && [ "z$aidm" = "z$i" ] ; then
	    mark=" *"
	    extf=""
	    eval "extf=\"\$AID${i}EXTF\""
	    if [ "z$extf" != "z" ] ; then
		# add external file to list of inputs and calculate
		# resulting AID:
		AID="$INC:${id#*:}"
		add_in_file "$extf"
	    else
		AID="$id"
	    fi
	fi
	echo "aid#$i: $desc$mark"
	incr i
    done
    if [ "z$AID" = "z" ] ; then
	if [ "z$AIDX" != "z" ] || [ "$AIDC" -gt 1 ] ; then
	    die "\"$aidx\" audio stream not found"
	else
	    echo "WARNING: \"$aidx\" audio stream not found" 1>&2
	fi
    fi
fi
if [ "z$AID" = "z" ] ; then AID="0:a:0" ; fi

# Detect max volume and raise it if THRESH_VOL is set:
if [ "z$ADD_VOL" = "z" ] && [ "z$THRESH_VOL" != "z" ] \
	&& [ "z$THRESH_VOL" != "znone" ] \
	&& [ "z$ID_MODE" != "z1" ] ; then
    ffmpeg="ffmpeg -hide_banner"
    i=0
    while [ "$i" -lt "$INC" ] ; do
	eval "g=\"\$IN${i}GRP\""
	append_grp2cmd "$g" ffmpeg "full"
	incr i
    done
    aresample="aresample=\${ARATE}och=2:osf=fltp:ocl=downmix"
    asyncts="asyncts=min_delta=\$ASD"
    teelog="2>&1 | tee \"\$TMP_OUT\""
    ffmpeg="$ffmpeg -map_metadata -1 -map_chapters -1 -sn -vn"
    ffmpeg="$ffmpeg -map \"\$AID\" -c:a \"\$AC\""
    ffmpeg="$ffmpeg -af \"\${AFPRE_OTHER}asyncts=min_delta=\$ASD"
    ffmpeg="$ffmpeg,aresample=\${ARATE}och=2:osf=fltp:ocl=downmix"
    ffmpeg="$ffmpeg,volumedetect\$AF_OTHER\" -f matroska -y /dev/null"
    if [ "z$TGRPN" != "z" ] ; then
	append_grp2cmd "$TGRPN" ffmpeg
    fi
    echo "$ffmpeg"
    eval "echo $ffmpeg"
    eval "$ffmpeg $teelog"
    MAX_VOL=""
    # [Parsed_volumedetect_1 @ 0xc92960] max_volume: -1.4 dB
    MAX_VOL="`sed -nr \
	's/^.* max_volume: *(-?)([0-9]+)(\.([0-9]+))?.*$/\1\2.\4/p' \
	<"$TMP_OUT"`"
    if [ "z$MAX_VOL" != "z" ] && [ "z1" = "z`bc <<EOF
	$MAX_VOL < $THRESH_VOL
EOF`" ] ; then
	ADD_VOL="`bc <<EOF
	-0.1 - $MAX_VOL
EOF`"
    fi
    # XXX : check for "asyncts dropping whole buffer" messages:
    if grep "asyncts.*drop.*whole buffer" "$TMP_OUT" >/dev/null ; then
	die "asyncts drops buffers, increase min_delay"
    fi
    # XXX : check for "[output stream 0:0 @ 0x7cbc80] 100 buffers queued
    # in output stream 0:0, something may be wrong." messages:
    if grep "something may be wrong" "$TMP_OUT" >/dev/null ; then
	die "something may be wrong"
    fi
fi
if [ "z$ADD_VOL" != "z" ] ; then
    AF_VOL=",volume=volume=+${ADD_VOL}dB"
fi

# Detect subtitles stream ID and filename:
if [ "z$SID" != "znone" ] ; then
    if ! [ -f "$TMP_OUT" ] ; then
	echo ffmpeg -i "$IN0"
	ffmpeg -i "$IN0" >"$TMP_OUT" 2>&1
    fi
    NSUB=0
    DEF_SID=""
    while read L ; do
	# detect default subs stream:
	case $L in
	    *Stream\ *:\ Subtitle:*\(default\))
		DEF_SID="$NSUB"
		;;
	esac
	# increment subs stream counter:
	case $L in
	    *Stream\ *:\ Subtitle:*)
		# store type of int subs in SUBSxx variable:
       		eval "SUBS$NSUB=\$L"
       		eval "SUBSSTOR$NSUB=int"
		echo "sid#$NSUB: $IN0, $L"
		NSUB="`expr 1 + "$NSUB"`"
		;;
	esac
    done <"$TMP_OUT"
    # Create search pattern for find ... -name ... Note: when the
    # old-style `` substitution is used, \$, \` and \\ sequences _are_
    # expanded before subshell is forked to execute the command:
    IN_FIND_NAME="`perl -wse \
	'$ARGV[0] =~ s/([]*?[])/\\\\$1/g; print $ARGV[0]' \
	-- "${IN0BNAME%.*}"`"
    # Look for .ass and .srt files:
    if [ "z$SUBSD" != "z" ] ; then
	subsd="$SUBSD"
    else
	subsd="$IN0DIR"
    fi
    find "$subsd" -name "$IN_FIND_NAME*.ass" \
	-o -name "$IN_FIND_NAME*.ASS" \
	-o -name "$IN_FIND_NAME*.srt" \
	-o -name "$IN_FIND_NAME*.SRT" | sort >"$TMP_OUT"
    while read f ; do
	if [ -f "$f" ] || [ -h "$f" ] ; then
	    # store .ass/.srt file name in SUBSxx variable:
	    eval "SUBS$NSUB=\"\$f\""
	    eval "SUBSSTOR$NSUB=ext"
	    echo "sid#$NSUB: $f"
	    NSUB="`expr 1 + "$NSUB"`"
	fi
    done <"$TMP_OUT"
    # If there's no default SID in input file, assume SID 0:
    [ "z$DEF_SID" = "z" ] && DEF_SID="0"
    # If SID parameter is empty, use default SID:
    case "z$SID" in
	z)        sid="$DEF_SID" ;;
	z[0-9]*)  sid="$SID"     ;;
	z-[0-9]*) sid="`expr "$NSUB" + "$SID"`" ;;
	*)        die "invalid -sid: $sid" ;;
    esac
    # Render subs if the specified stream is found:
    if [ 0 -le $sid ] && [ $sid -lt $NSUB ] ; then
	eval "s=\"\$SUBS$sid\""	; # s=$SUBS0, s=$SUBS1 etc...
				  # depending on $sid
	eval "sstor=\"\$SUBSSTOR$sid\""
	if [ "z$sstor" = "zint" ] ; then
	    echo "selecting $sstor sid#$sid: $IN0, $s"
	    case $s in
		*Stream\ *:\ Subtitle:\ subrip*)
		    SUBS_FILTER="subtitles"
		    TMP_SUBS="${TMPF}.srt"
		    ;;
		*Stream\ *:\ Subtitle:\ ass*)
		    if [ "z$SUBS_FILTER" = "z" ] ; then
			SUBS_FILTER="ass"
		    fi
		    TMP_SUBS="${TMPF}.ass"
		    ;;
		*)  die "unsupported sid#$sid: $s" ;;
	    esac
	    # extract subtitles to tmp file:
	    echo ffmpeg -i "$IN0" \
		-map_metadata -1 -map_chapters -1 \
		-an -vn -map "0:s:$sid" -c:s copy \
		-y "$TMP_SUBS"
	    ffmpeg -i "$IN0" \
		-map_metadata -1 -map_chapters -1 \
		-an -vn -map "0:s:$sid" -c:s copy \
		-y "$TMP_SUBS" 2>&1 | tee "$TMP_OUT"
	elif [ "z$sstor" = "zext" ] ; then
	    echo "selecting $sstor sid#$sid: $s"
	    case $s in
		*.ass|*.ASS)
		    if [ "z$SUBS_FILTER" = "z" ] ; then
			SUBS_FILTER="ass"
		    fi
		    TMP_SUBS="${TMPF}.ass"
		    ;;
		*.srt|*.SRT)
		    SUBS_FILTER="subtitles"
		    TMP_SUBS="${TMPF}.srt"
		    ;;
	    esac
	    rm -f "$TMP_SUBS"
	    # we need absolute filename for symlink target:
	    sdir="${s%/*}"
	    sbase="${s##*/}"
	    if [ "z$sdir" = "z" ] ; then
		sdir="/"
	    elif [ "z$sdir" = "z$s" ] ; then
		sdir="`pwd`"
	    else
		cd "$sdir" ; sdir="`pwd`" ; cd "$OLDPWD"
	    fi
	    case "$sdir" in */) ;; *) sdir="$sdir/" ;; esac
	    ln -s "$sdir$sbase" "$TMP_SUBS"
	else
	    # XXX: sstor must be either int or ext
	    die "unknown storage for sid#$sid"
	fi
	if [ "z$TMP_SUBS" != "z" ] ; then
	    # autodetect subs encoding unless SUBCP has been
	    # explicitly specified on cmdline:
	    if [ "z$SUBCP" != "z" ] ; then
		subcp="$SUBCP"
	    else
		if check_fileencoding "$TMP_SUBS" utf8 ; then
		    subcp="utf-8"
		elif iconv -f utf-16 -t utf-8 <"$TMP_SUBS" \
		>/dev/null 2>&1 ; then
		    subcp="utf-16"
		elif iconv -f cp1251 -t utf-8 <"$TMP_SUBS" \
		>/dev/null 2>&1 ; then
		    subcp="cp1251"
		else
		    die "unknown sid#$sid ($s) encoding"
		fi
	    fi
	    # XXX: "ass" filter doesn't take charenc= option
	    # and sometimes srt decoder fails with the next
	    # message:
	    #   [srt @ 0x141b160] Unable to recode subtitle
	    #   event "..." from utf-16 to UTF-8
	    # Therefore we explicitly pass .ass/.srt files
	    # through iconv before rendering subs:
	    if [ "z$SUBS_FILTER" = "zass" ] \
	    ||	[ "z$SUBS_FILTER" = "zsubtitles" ] ; then
		case $subcp in
		    utf-8|UTF-8|utf8|UTF8)
			echo "file $TMP_SUBS" \
			    "is already in $subcp"
			subcp=""
			;;
		    ?*)
			echo "recoding $TMP_SUBS" \
			    "from $subcp to utf-8"
			if [ "z$SUBCP" != "z" ] ; then
			    # force conversion:
			    iconv -f "$subcp" -t "utf-8" -c \
				<"$TMP_SUBS" >"$TMP_OUT"
			    mv "$TMP_OUT" "$TMP_SUBS"
			else
			    # attempt conversion:
			    if iconv -f "$subcp" -t "utf-8" \
			    <"$TMP_SUBS" >"$TMP_OUT" \
			    && mv "$TMP_OUT" "$TMP_SUBS" ; then
				true
			    else
				die "recoding $TMP_SUBS" \
				    "from $subcp to utf-8 failed"
			    fi
			fi
			subcp=""
			;;
		esac
	    fi
	    # convert to UNIX line endings:
	    if perl -p -wse 's/\r*\n/\n/g' <"$TMP_SUBS" >"$TMP_OUT" \
	    && mv "$TMP_OUT" "$TMP_SUBS" ; then
		true
	    else
		die "converting $TMP_SUBS" \
		    "to UNIX line endings failed"
	    fi
	    if [ "z$subcp" != "z" ] ; then
		subcp=":charenc=${subcp}"
	    fi
	    if [ "z$SUBSS" != "z" ] ; then
		# XXX: "ass" filter doesn't accept force_style
		# option, therefore we fallback to "subtitles":
		SUBS_FILTER="subtitles"
		SUBSS=":force_style=${SUBSS}"
	    fi
	    VF_SUBS=",$SUBS_FILTER=${TMP_SUBS}${subcp}${SUBSS}"
	fi
    fi
fi

rm -f "$TMP_OUT"

if [ "z$ID_MODE" = "z1" ] ; then
    rm -f "${TMPF}".*
    exit 0
fi

ffmpeg="ffmpeg -hide_banner"
i=0
while [ "$i" -lt "$INC" ] ; do
    eval "g=\"\$IN${i}GRP\""
    append_grp2cmd "$g" ffmpeg "full"
    incr i
done
ffmpeg="$ffmpeg -map_metadata -1"
ffmpeg="$ffmpeg -map_chapters -1"
ffmpeg="$ffmpeg -map \"\$VID\""
ffmpeg="$ffmpeg -c:v libx264"
ffmpeg="$ffmpeg -filter_complex \"null\${VFPRE_OTHER}"
ffmpeg="$ffmpeg\${VF_SCALE}\${VF_SUBS}\${VF_OTHER}\""
ffmpeg="$ffmpeg -map \"\$AID\""
ffmpeg="$ffmpeg -c:a \"\$AC\""
ffmpeg="$ffmpeg -ac 2"
ffmpeg="$ffmpeg -af \"\${AFPRE_OTHER}asyncts=min_delta=\$ASD"
ffmpeg="$ffmpeg,aresample=\${ARATE}och=2:osf=fltp:ocl=downmix"
ffmpeg="$ffmpeg\${AF_VOL}\${AF_OTHER}\""
if [ "z$ALANG" != "z" ] ; then
    ffmpeg="$ffmpeg -metadata:s:a \"language=\$ALANG\""
fi

if [ "z$TMP_PASS" = "z" ] ; then
    append_grp2cmd "$OUT0GRP" ffmpeg
    ffmpeg="$ffmpeg $OVWR_OUT \"\$OUT0\""
    if [ "z$TGRPN" != "z" ] ; then
	append_grp2cmd "$TGRPN" ffmpeg
    fi
    echo "$ffmpeg"
    eval "echo $ffmpeg"
    eval "$ffmpeg </dev/null"
else
    ffmpeg1="$ffmpeg -pass 1 -passlogfile \"\$TMP_PASS\""
    append_grp2cmd "$OUT0GRP" ffmpeg1
    ffmpeg1="$ffmpeg1 $OVWR_OUT \"\$OUT0\""
    ffmpeg2="$ffmpeg -pass 2 -passlogfile \"\$TMP_PASS\""
    append_grp2cmd "$OUT0GRP" ffmpeg2
    ffmpeg2="$ffmpeg2 -y \"\$OUT0\""
    if [ "z$TGRPN" != "z" ] ; then
	append_grp2cmd "$TGRPN" ffmpeg1
	append_grp2cmd "$TGRPN" ffmpeg2
    fi
    echo "$ffmpeg1"
    eval "echo $ffmpeg1"
    eval "$ffmpeg1 </dev/null"
    E="$?" ; if [ "z$E" != "z0" ] ; then die "$E" ; fi
    echo "$ffmpeg2"
    eval "echo $ffmpeg2"
    eval "$ffmpeg2 </dev/null"
fi

if [ "z$TMP_PASS" != "z" ] ; then
    rm -f "$TMP_PASS"*
fi
if [ "z$TMP_SUBS" != "z" ] ; then
    rm -f "$TMP_SUBS"
fi

# vi:set sw=4 noet ts=8 tw=71:
