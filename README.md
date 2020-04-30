# ldraw2stl

Convert LEGO LDraw files to STL, for super-sizing and 3d printing!!

1) Get the ldraw parts archive at [](http://www.ldraw.org/article/13.html):

    wget http://www.ldraw.org/library/updates/complete.zip
    unzip complete.zip
    bin/dat2stl --file ldraw/parts/3894.dat --ldrawdir ./ldraw

2) Install LeoCAD so you can find your parts (optional)

3) Make a note of the .dat file name in LeoCAD, and then run:

  bin/dat2stl --file /usr/share/ldraw/parts/3894.dat --ldrawdir ./ldraw --scale 4 > 3894.stl

For a 4X scale one of those!
