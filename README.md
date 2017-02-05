# recode-vid
Resize &amp; add subtitles to video (using ffmpeg).

recode-vid.sh is a wrapper around ffmpeg that simplifies recoding video
files for viewing on tablet computers. Typically it performs the next
tasks:
* resize video while keeping correct aspect,
* normalize SAR to 1:1 (necessary for viewing on some tablet
  computers, e.g. Amazon Kindle Fire),
* select audio track by language id (e.g. "jpn"),
* normalize audio volume (when downmixing from 5.1 or more channels,
  resulting audio is often too quiet),
* detect buffer drops due to large audio timestamps jitter,
* search for matching external audio files in input subdirectories,
* search for matching external subtitle files in input subdirectories,
* render subtitles over video (hardsub).

The script is most useful for recoding anime tv series, when each video
file has several audio tracks and external fansubs in various languages
("jpn", "rus", "eng" etc).
