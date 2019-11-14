King Albert's Patience
======================

Requires Lua 5.3+, Lgi, Gtk3, GooCanvas2. Also ImageMagick to create
the card images as .png, unless you prefer to substitute some decent
artwork for my horrible efforts (when I wrote the Tcl version of this,
20-odd years ago, I was on metered dialup and wasn't inclined to go
searching for usable clipart).

Click on card to select, click on destination to move (no dragging).
Right-click to view a partially-covered card. Also, right-click on
an empty depot moves a single selected card, rather than a maximal
sequence. Double-click will move an eligible card to its foundation.
Cards will be moved to foundations automatically, too.

The rules only allow moving one card at a time, but the program will
compute most move sequences for you, using empty depots and exposed
depot cards for staging. It will **not** currently compute move
sequences that stage via the foundations.
