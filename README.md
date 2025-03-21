# ldraw2stl

Convert LEGO LDraw files to STL, for super-sizing and 3d printing!!

1) Locate the ldraw parts archive at [getting started](https://www.ldraw.org/help/getting-started.html) (note: the `wget` link below might go stale):
2) Install LeoCAD so you can find your parts (optional)
3) Make a note of the .dat file name in LeoCAD, and then run:

```
wget https://library.ldraw.org/library/updates/complete.zip
unzip complete.zip
bin/dat2stl --file ldraw/parts/3894.dat --ldrawdir ./ldraw > 3894.stl
```

Use the `--scale` argument to scale the part:

```
bin/dat2stl --file /usr/share/ldraw/parts/3894.dat --ldrawdir ./ldraw --scale 4 > 3894.stl
```

For a 4X scale one of those!

## Windows users

A user reported that they were able to get the tool to work on Windows using [Strawberry Perl](https://strawberryperl.com/). However, they encountered an issue that Powershell redirection under Windows will by default create a unicode file. Apparently STL readers interpret this as a binary file (because STL has both binary and ascii specifications) and fail to read it. To force ascii redirection use:

```
perl bin/dat2stl --file [part file] --ldrawdir [ldraw library] | Out-File -Encoding Ascii [output.stl]
```
