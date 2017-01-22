#!/bin/sh

usage() {
    PROG="$1"
    echo "USAGE: $PROG [opts] in out
    opts:
	-ac	X	use audio codec X
	-af	F	append audio filter F
	-afpre	F	prepend audio filter F
	-aid	N	select Nth audio stream
	-alang	L	set audio stream language L
	-arate	R	set audio rate R
	-asd	S	set asyncts min_delta to S
	-h	H	scale to height H
	-sid	N	select Nth subtitles stream
	-subcp	X	assume codepage X for input subtitles
	-subss	X	force subs style X (e.g. Fontstyle=40)
	-tvol	T	set volume threshold at T dB
	-vf	F	append video filter F
	-vfpre	F	prepend video filter F
	-vid	N	select Nth video stream
	-vol	A	increase volume by A dB
	-w	W	scale to width W"
    exit 1
}

# check file for utf8 encoding: 0-utf8 1-other
check_fileencoding() {
    perl -ws -- - "$1" "$2" <<EOF
	use Encode qw(encode decode);
	my (\$fn, \$enc, \$thresh) = @ARGV;
	die "check_fileencoding: filename is required\\n"
	    if not defined \$fn;
	\$enc = "utf8" if not defined \$enc;
	\$thresh = 0.01 if not defined \$thresh;
	open my \$fh, "<", \$fn or die \$!;
	my (\$bad, \$total) = (0, 0);
	while (<\$fh>) {
	    \$total += length(\$_);
	    decode(\$enc, \$_, sub {\$bad++; return "\\x{FFFD}"});
	};
	close \$fh;
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
SUBSS=""	; # forced subtitles style
SUBS_FILTER=""	; # "ass" "or subtitles"
VF_SUBS=""	; # "subtitles"/"ass" video filter with params
VF_SCALE=",scale=w=720:h=ceil(ih*ow/iw/sar/2)*2,setsar=sar=1"
VF_OTHER=""	; # other video filters to append
VFPRE_OTHER=""	; # other video filters to prepend
# audio params:
AID=""
AC="libvorbis"	; # audio codec
ARATE=""
ASD="0.3"	; # asyncts min_delta [0.3s]. You need to increase it
		  # if you get messages like "[Parsed_asyncts_0 @
		  # 0x1719be0] Non-monotonous timestamps, dropping
		  # whole buffer." XXX
ALANG=""	; # audio language (e.g. rus, jpn, eng)
META_ALANG=""	; # output audio language tag
ADD_VOL=""	; # additional audio volume
THRESH_VOL="-0.5" ; # volume threshold for autoincrease
AF_VOL=""	; # "volume" audio filter
AF_OTHER=""	; # other audio filters to append
AFPRE_OTHER=""	; # other audio filters to prepend
# other params:
OVWR_OUT="-y"	; # "overwrite output file" option
ARG_CNT=0	; # arguments counter
CUR_OPT="none"	; # current option
# in/out/tail argument groups:
GRPC=0		; # argument groups counter
ARGC=0		; # group arguments counter
INC=0		; # input groups counter
OUTC=0		; # output groups counter
TGRPN=""	; # tail group number

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
		case "$A" in
		    *:a:*|*:\#*:*|none) AID="$A" ;;
		    *:*:*) die "invalid -aid $A" ;;
		    \#*:*) AID="0:$A" ;;
		    *) AID="0:a:$A" ;;
		esac
		CUR_OPT="none"
		;;
	    -alang)
		ALANG="$A"
		META_ALANG="-metadata:s:a language=$A"
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
	    -n)
		OVWR_OUT="-n"
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
	    -y)
		OVWR_OUT="-y"
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
				usage "$0"
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
    [ "z$ARG_CNT" = "z2" ] || usage "$0"
}

parse_args "$@"

# Detect audio stream ID:
if [ "z$AID" = "z" ] && [ "z$ALANG" != "z" ] ; then
    ffmpeg="ffmpeg -hide_banner"
    i=0
    while [ "$i" -lt "$INC" ] ; do
	ffmpeg="$ffmpeg -i \"\$IN$i\""
	incr i
    done
    eval "echo $ffmpeg"
    eval "$ffmpeg >\"\$TMP_OUT\" 2>&1"
    NAUD=0
    DEF_AID=""
    while read L ; do
	# Stream #0:1(rus): Audio: aac (HE-AAC), 44100 Hz, 5.1,
	# fltp (default)
	# Stream #0:1[0x1100]: Audio: pcm_bluray (HDMV / 0x564D4448),
	# 48000 Hz, stereo, s16, 1536 kb/s
	case $L in
	    *Stream\ *:\ Audio:\ *)
		id="${L#*Stream #}"
		id="${id%%: Audio*}"
		aid="${id%%(*}"
		aid="${aid%%\[*}"
		lng="${id#*(}"
		lng="${lng%%)*}"
		cdc="${L#*Stream*Audio: }"
		case "$cdc" in
		    *\(default\))
			DEF_AID="$NAUD"
			cdc="${cdc% (default)}"
			;;
		esac
		sel=""
		if [ "z$AID" = "z" ] \
		    && [ "z$lng" = "z$ALANG" ] ; then
		    AID="$aid"
		    sel=" *"
		fi
		echo "aid#$NAUD: #$aid($lng): $cdc$sel"
		NAUD="`expr 1 + "$NAUD"`"
		;;
	esac
    done <"$TMP_OUT"
    if [ "z$AID" = "z" ] ; then
	die "($ALANG) audio stream not found"
    fi
fi
if [ "z$AID" = "z" ] ; then AID="0:a:0" ; fi

# Detect max volume and raise it if THRESH_VOL is set:
if [ "z$ADD_VOL" = "z" ] && [ "z$THRESH_VOL" != "z" ] \
	&& [ "z$THRESH_VOL" != "znone" ] ; then
    ffmpeg="ffmpeg -hide_banner"
    i=0
    while [ "$i" -lt "$INC" ] ; do
	ffmpeg="$ffmpeg -i \"\$IN$i\""
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
    find "$IN0DIR" -name "$IN_FIND_NAME*.ass" \
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
		    SUBS_FILTER="ass"
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
		    SUBS_FILTER="ass"
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
ffmpeg="$ffmpeg $META_ALANG"

if [ "z$TMP_PASS" = "z" ] ; then
    ffmpeg="$ffmpeg $OVWR_OUT \"\$OUT0\""
    if [ "z$TGRPN" != "z" ] ; then
	append_grp2cmd "$TGRPN" ffmpeg
    fi
    echo "$ffmpeg"
    eval "echo $ffmpeg"
    eval "$ffmpeg </dev/null"
else
    ffmpeg1="$ffmpeg -pass 1 -passlogfile \"\$TMP_PASS\""
    ffmpeg1="$ffmpeg1 $OVWR_OUT \"\$OUT0\""
    ffmpeg2="$ffmpeg -pass 2 -passlogfile \"\$TMP_PASS\""
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
