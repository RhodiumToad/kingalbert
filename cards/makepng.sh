#!/bin/sh -e

for f in *heart.xbm *diamond.xbm
do
    convert \( -fill "#dd0000" -opaque black "$f" \) \
	    \( cardmask.xbm -negate \) \
	    -compose CopyOpacity -composite \
	    "${f%.xbm}.png"
    convert \( -fill "#dd0000" -opaque black "$f" -negate \) \
	    \( cardmask.xbm -negate \) \
	    -compose CopyOpacity -composite \
	    "r${f%.xbm}.png"
done        

for f in *club.xbm *spade.xbm
do
    convert \( -fill black -opaque black "$f" \) \
	    \( cardmask.xbm -negate \) \
	    -compose CopyOpacity -composite \
	    "${f%.xbm}.png"
    convert \( -fill black -opaque black "$f" -negate \) \
	    \( cardmask.xbm -negate \) \
	    -compose CopyOpacity -composite \
	    "r${f%.xbm}.png"
done
