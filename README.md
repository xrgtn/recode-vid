# recode-vid
Resize &amp; add subtitles to video (using ffmpeg).

recode-vid.sh is a wrapper around ffmpeg that simplifies recoding video
files for viewing on tablet computers. Typically it performs the next
tasks:
* resize video while keeping correct aspect,
* normalize SAR to 1:1 (necessary for viewing on some tablet
  computers, e.g. Amazon Kindle Fire),
* search for matching external audio files in input subdirectories,
* select audio track by language id (e.g. "jpn"), description or
  pathname,
* normalize audio volume (when downmixing from 5.1 or more channels,
  resulting audio is often too quiet),
* detect buffer drops due to large audio timestamps jitter,
* search for matching external subtitle files in input subdirectories,
* select subtitles by language, description or pathname,
* render subtitles over video (hardsub).

The script is most useful for recoding anime tv series, when each video
file has several audio tracks and external fansubs in various languages
("jpn", "rus", "eng" etc).

Its most useful feature is ability to search for external audio and
subtitle files in subdirectories near main video files. For example, if
main video file is called
"[Yousei-raws] Kuuchuu Buranko 07 [BDrip 1920x1080 x264 FLAC].mkv",
the script is able to find matching fandub file:
* "RUS Sound [Vulpes Vulpes]/[Yousei-raws] Kuuchuu Buranko 07 [BDrip 1920x1080 x264 FLAC].mka"

and matching fansubs:
* "RUS Subs [NWP]/[Yousei-raws] Kuuchuu Buranko 07 [BDrip 1920x1080 x264 FLAC].ass"
* "RUS Subs [NWP]/[Yousei-raws] Kuuchuu Buranko 07 [BDrip 1920x1080 x264 FLAC].censored version.ass"

If neither -aid nor -alang option is specified the script picks up the
default audio stream. If no default stream is found, it picks up the
1st audio stream (internal streams are considered first, external
streams next). If -alang is specified while -aid is not, -alang's value
is used as audio stream "selector". If -aid option is specified, its
value overrides -alang's one and is used as a "selector" instead.

Subtitles are selected in a similar way except there's no -slang
option, only -sid one.

Video stream selectors are not supported at the moment.

Audio and subtitles "selectors" may be composed of several positive
and/or negative case-sensitive patterns, separated/prefixed by ':' and
'!', and for a selector to match a stream, all of its patterns must
match the stream's description. Negative patterns start with '!',
positive start with ':'. If first pattern in selector isn't prefixed,
it's assumed to be positive.  For example, -sid 'rus!default:srt' is
split into 3 patterns - ':rus', '!default' and ':srt' and it matches
non-default russian srt subtitle streams. If there's more than one
matching stream, 1st one is selected unless selector contains a number.
For example, 'rus:0' matches 1st russian stream, '1' matches 2nd
stream, '-1:eng' matches last english stream and 'jap:-2' matches last
but one japanese.

Logical ORing or grouping of patterns isn't supported in stream
selectors.
