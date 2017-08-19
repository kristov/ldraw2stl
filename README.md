# ldraw2stl

Convert LEGO LDraw files to STL, for super-sizing and 3d printing!!

1) Get the ldraw parts archive at http://www.ldraw.org or apt-get install ldraw-parts

2) Install LeoCAD so you can find your parts

3) Make a note of the .dat file name in LeoCAD, and then run:

  bin/dat2stl --file /usr/share/ldraw/parts/3894.dat --scale 4 > 3894.stl

For a 4X scale one of those!

Depends on Moose.
