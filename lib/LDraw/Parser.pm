package LDraw::Parser;

use strict;
use warnings;
use File::Spec;

# A meta command is a comment line (type 0) followed by some magic. Unfortunately, being a
# comment line it can also be followed by regular old comments. Here are some common words
# that are the first word in a comment line, which are not meta commands we need to
# consider.
#
my @META_IGNORE = (
    "Hi-Res",
    "Name:",
    "Author:",
    "!LDRAW_ORG",
    "!LICENSE",
    "!HISTORY",
    "Technic",
    "Box",
    "Cylinder",
    "Peg",
    "Rectangle",
    "Stud",
);
my %MI = map {lc($_) => 1} @META_IGNORE;

sub new {
    my ($class, $args) = @_;
    die "file required" unless $args->{file};
    return bless({
        file => $args->{file},
        ldraw_path => $args->{ldraw_path} // '/usr/share/ldraw',
        scale => $args->{scale} // 1,
        mm_per_ldu => $args->{mm_per_ldu} // 0.4,
        invert => $args->{invert} // 0,
        debug => $args->{debug} // 0,
        d_indent => $args->{d_indent} // 0,
        ccw_winding => 1,
        _invertnext => 0,
    }, $class);
}

sub _getter_setter {
    my ($self, $key, $value) = @_;
    if (defined $value) {
        $self->{$key} = $value;
    }
    return $self->{$key};
}

# The file to parse
sub file { return shift->_getter_setter('file', @_); }

# Where to find ldraw files
sub ldraw_path { return shift->_getter_setter('ldraw_path', @_); }

# Scale the model
sub scale { return shift->_getter_setter('scale', @_); }

# Number of mm per LDU (LDraw Unit)
sub mm_per_ldu { return shift->_getter_setter('mm_per_ldu', @_); }

# Invert this part
sub invert { return shift->_getter_setter('invert', @_); }

# Specify the winding order of triangles in this part
sub ccw_winding { return shift->_getter_setter('ccw_winding', @_); }

# Print debugging messages to stderr
sub debug { return shift->_getter_setter('debug', @_); }

# Indentation for debug messages (for subfiles)
sub d_indent { return shift->_getter_setter('d_indent', @_); }

use constant X => 0;
use constant Y => 1;
use constant Z => 2;

sub DEBUG {
    my ($self, $message, @args) = @_;
    return if !$self->debug;
    my $indent = " " x $self->d_indent;
    if (@args) {
        $message = sprintf($message, @args);
    }
    print STDERR sprintf("%sDEBUG: %s\n", $indent, $message);
}

sub WARN {
    my ($self, $class, $message, @args) = @_;
    my $indent = " " x $self->d_indent;
    if (@args) {
        $message = sprintf($message, @args);
    }
    $self->{_warn_classes}->{$class}++;
    print STDERR sprintf("%sWARN: [%s] %s\n", $indent, $class, $message);
}

sub parse {
    my ( $self ) = @_;
    return $self->parse_file( $self->file );
}

sub parse_file {
    my ( $self, $file ) = @_;
    open( my $fh, '<', $file ) || die "$file: $!";
    $self->parse_handle( $fh );
    close $fh;
}

sub parse_handle {
    my ( $self, $handle ) = @_;
    while ( my $line = <$handle> ) {
        chomp $line;
        $self->parse_line( $line );
    }
}

# The BFC CERTIFY [CCW|CW] meta command determines the winding. But if we are inverting
# the part, we have to invert this winding.
#
sub use_ccw_winding {
    my ($self) = @_;
    return ($self->invert) ? !$self->ccw_winding : $self->ccw_winding;
}

# The default winding of triangles is CCW (Counter ClockWise). A triangle wound CCW on the
# X,Y plane will have it's normal vector pointing in the positive Z direction. This is
# usually towards the screen, so likely towards a light source. By default, all ldraw
# geometry is wound CCW, and this is made explicit by the meta command:
#
#   0 BFC CERTIFIED CCW
#
# However, a part file may change this winding order by using "BFC CERTIFIED CW". This
# will flip the normal vector to be pointing in the other direction. For example, if we
# are generating the inside surface of a tube rather than the outside.
#
# The "invert" parameter changes this winding for a part. So if the part is CCW, the
# invert param flips this to CW. This inversion is "sticky", meaning it will be applied to
# a part and all it's sub-parts, until the inversion rule is flipped.
#
# The inversion rule is flipped under two circumstances: 1. An "INVERTNEXT" BFC meta
# command is seen, and 2. If this code detects there is a reflection transformation.
#
# The "INVERTNEXT" meta command in theory applies to the next line in a file, however in
# this code it only affects the next sub-part (parse_sub_file_reference). I have yet to
# see it be applied to a triangle or quad line.
#
# A reflection transformation will flip the winding order of the triangles. Therefore, the
# invert param is set so that the sub-part is generated with the inverted winding. When
# the reflection transformation is applied, the winding is set back to the expected
# winding for the sub-part.
#
sub compute_inversion {
    my ($self, $mat) = @_;

    # Use the passed invert state, unless we are doing an INVERTNEXT
    my $invert = ($self->{_invertnext}) ? !$self->invert : $self->invert;

    # A negative determinant means there is some form or reflection happening. When this
    # matrix is applied to the vertexes of the sub-part, the winding order of the vertexes
    # is reversed. So if we detect a negative determinant, we have to flip the winding
    # order of the sub-part so that when this matrix is applied the original intended
    # winding is preserved.
    my $det = mat4determinant($mat);
    $invert = ($det < 0) ? !$invert : $invert;

    return $invert;
}

# Lines start with a line type, which is an integer. The type defines the format of the
# rest of the line.
#
sub parse_line {
    my ($self, $line) = @_;

    $line =~ s/^\s+//;

    if ( $line =~ /^([0-9]+)\s+(.+)$/ ) {
        my ( $line_type, $rest ) = ( $1, $2 );
        if ( $line_type == 0 ) {
            $self->parse_comment_or_meta( $rest );
        }
        elsif ( $line_type == 1 ) {
            $self->parse_sub_file_reference( $rest );
        }
        elsif ( $line_type == 2 ) {
            $self->parse_line_command( $rest );
        }
        elsif ( $line_type == 3 ) {
            $self->parse_triange_command( $rest );
        }
        elsif ( $line_type == 4 ) {
            $self->parse_quadrilateral_command( $rest );
        }
        elsif ( $line_type == 5 ) {
            $self->parse_optional( $rest );
        }
        else {
            $self->WARN("UNKNOWN_LINE_TYPE", "unhandled line type: %s", $line_type);
        }
    }
}

# Comments can usually be ignored, except for the "BFC" meta command. This is used to
# define the winding order of triangles in the file (Back Face Culling).
#
# "Changing the winding setting will only affect the current file. It will not modify the
# winding of subfiles."
#
# I need to check this, because I think my logic might be flawed here.
#
sub parse_comment_or_meta {
    my ($self, $rest) = @_;
    my @items = split(/\s+/, $rest);
    my $first = shift @items;

    if (!$first) {
        return;
    }
    if ($first eq '//') {
        # The form 0 // <comment> is preferred as the // marker clearly indicates that the
        # line is a comment, thereby permitting parsers to stop processing the line. The
        # form 0 <comment> is deprecated. 
        return;
    }
    if ($MI{lc($first)}) {
        return;
    }
    if ($first eq 'BFC') {
        $self->handle_bfc_command(@items);
        return;
    }
    #$self->WARN("UNKNOWN_META", "unknown meta command: %s", $first);
}

sub handle_bfc_command {
    my ($self, @items) = @_;

    my $first = shift @items;

    if (!$first) {
        $self->DEBUG('META: invalid BFC');
        return;
    }
    if ($first eq 'INVERTNEXT') {
        $self->{_invertnext} = 1;
        $self->DEBUG('META: INVERTNEXT found while invert[%d]', $self->invert);
        return;
    }
    if ($first eq 'CERTIFY') {
        my $winding = $items[0];
        if (!$winding) {
            $self->DEBUG('META: CERTIFY with no winding - default CCW');
            return;
        }
        if ($winding eq 'CW') {
            $self->ccw_winding(0);
        }
        return;
    }
    $self->DEBUG('META: Unknown BFC: %s', $items[0]);
}

# A sub-file reference is a shape described in another file, placed in a certain location
# in the model. Note: this is recursive, so sub-files can contain references to other
# sub-files. The first number is a color (ignored) followed by a 3x3 translation matrix
# for how to position the sub-file shape within the model. This matrix encodes rotation
# and translation, and is converted here into a 4x4 matrix with "identity" set for the
# skew part of the matrix.
#
sub parse_sub_file_reference {
    my ($self, $rest) = @_;
    # 16 0 -10 0 9 0 0 0 1 0 0 0 -9 2-4edge.dat
    my @items = split(/\s+/, $rest);
    my $color = shift @items;
    my $x = shift @items;
    my $y = shift @items;
    my $z = shift @items;
    my $a = shift @items;
    my $b = shift @items;
    my $c = shift @items;
    my $d = shift @items;
    my $e = shift @items;
    my $f = shift @items;
    my $g = shift @items;
    my $h = shift @items;
    my $i = shift @items;

    # The form of this matrix is:
    #
    #   / a b c x \
    #   | d e f y |
    #   | g h i z |
    #   \ 0 0 0 1 /
    #
    # Note: The x,y,z translation part are the first 3 arguments.

    my $mat = [
        $a, $b, $c, $x,
        $d, $e, $f, $y,
        $g, $h, $i, $z,
        0, 0, 0, 1,
    ];

    if (scalar(@items) != 1) {
        warn "um, filename is made up of multiple parts (or none)";
    }

    my $filename = lc($items[0]);
    $filename =~ s/\\/\//g;

    # This is the layout of the ldraw library:
    #
    #   ldraw
    #   ├── models
    #   ├── p
    #   │   ├── 48
    #   │   └── 8
    #   └── parts
    #       ├── s
    #       └── textures
    #
    # From the Readme.txt file:
    #
    #  \MODELS\     -  This directory is where your model .dat files are stored.
    #                  There are two sample model .dat files installed for you
    #                  to look at - Car.dat and Pyramid.dat.
    #  \P\          -  This directory is where parts primitives are located.
    #                  Parts primitives are tyically highly reusable components
    #                  used by the part files in the LDraw library.
    #  \P\48\       -  This directory is where high resolution parts primitives
    #                  are located. These are typically used for large curved
    #                  parts where excessive scaling of the regular curved
    #                  primitives would produce an undesriable result.
    #  \PARTS\      -  This directory holds all the actual parts that can be used
    #                  in creating or rendering your models.  A list of these
    #                  parts can be seen by viewing the parts.lst file.
    #  \PARTS\S\    -  This directory holds sub-parts that are used by the LDraw
    #                  parts to optimise file size and improve parts development
    #                  efficiancy.
    #
    my $p_filename = File::Spec->catfile($self->ldraw_path, 'p', $filename);
    my $hires_filename = File::Spec->catfile($self->ldraw_path, 'p', '48', $filename);
    my $parts_filename = File::Spec->catfile($self->ldraw_path, 'parts', $filename);
    my $parts_s_filename = File::Spec->catfile($self->ldraw_path, 'parts', 's', $filename);

    my $subpart_filename;
    if (-e $hires_filename) {
        $subpart_filename = $hires_filename;
    }
    elsif (-e $p_filename) {
        $subpart_filename = $p_filename;
    }
    elsif (-e $parts_filename) {
        $subpart_filename = $parts_filename;
    }
    elsif (-e $parts_s_filename) {
        $subpart_filename = $parts_s_filename;
    }
    else {
        warn "unable to find file: $filename in normal paths";
        return;
    }

    my $subparser = __PACKAGE__->new( {
        file       => $subpart_filename,
        ldraw_path => $self->ldraw_path,
        debug      => $self->debug,
        invert     => $self->compute_inversion($mat),
        d_indent   => $self->d_indent + 2,
    } );
    $subparser->parse;
    $self->{_invertnext} = 0;

    for my $triangle ( @{ $subparser->{triangles} } ) {
        for my $vec ( @{ $triangle } ) {
            my @new_vec = mat4xv3( $mat, $vec );
            $vec->[0] = $new_vec[0];
            $vec->[1] = $new_vec[1];
            $vec->[2] = $new_vec[2];
        }
        push @{ $self->{triangles} }, $triangle;
    }
}

# Lines are used for outlining the model so it is easier to see edges. Because we are
# generating data for an STL we don't need lines.
sub parse_line_command {
    my ( $self, $rest ) = @_;
}

# Optional lines are strange things, but they appear to be about not drawing lines that
# are occluded by the model. I think. Regardless, we don't need lines or optional lines
# for STL generation.
sub parse_optional {
    my ( $self, $rest ) = @_;
}

sub parse_triange_command {
    my ( $self, $rest ) = @_;
    # 16 8.9 -10 58.73 6.36 -10 53.64 9 -10 55.5
    my @items = split( /\s+/, $rest );
    my $color = shift @items;
    if ($self->use_ccw_winding) {
        $self->_add_triangle([
            [$items[0], $items[1], $items[2]],
            [$items[3], $items[4], $items[5]],
            [$items[6], $items[7], $items[8]],
        ]);
    }
    else {
        $self->_add_triangle([
            [$items[0], $items[1], $items[2]],
            [$items[6], $items[7], $items[8]],
            [$items[3], $items[4], $items[5]],
        ]);
    }
}

sub parse_quadrilateral_command {
    my ( $self, $rest ) = @_;
    # 16 1.27 10 68.9 -6.363 10 66.363 10.6 10 79.2 7.1 10 73.27
    my @items = split( /\s+/, $rest );
    my $color = shift @items;
    my $x1 = shift @items;
    my $y1 = shift @items;
    my $z1 = shift @items;
    my $x2 = shift @items;
    my $y2 = shift @items;
    my $z2 = shift @items;
    my $x3 = shift @items;
    my $y3 = shift @items;
    my $z3 = shift @items;
    my $x4 = shift @items;
    my $y4 = shift @items;
    my $z4 = shift @items;
    if ($self->use_ccw_winding) {
        $self->_add_triangle([
            [$x1, $y1, $z1],
            [$x2, $y2, $z2],
            [$x3, $y3, $z3],
        ]);
        $self->_add_triangle([
            [$x3, $y3, $z3],
            [$x4, $y4, $z4],
            [$x1, $y1, $z1],
        ]);
    }
    else {
        $self->_add_triangle([
            [$x1, $y1, $z1],
            [$x3, $y3, $z3],
            [$x2, $y2, $z2],
        ]);
        $self->_add_triangle([
            [$x3, $y3, $z3],
            [$x1, $y1, $z1],
            [$x4, $y4, $z4],
        ]);
    }
}

sub _add_triangle {
    my ($self, $points) = @_;
    push @{$self->{triangles}}, $points;
}

sub calc_surface_normal {
    my ($self, $points) = @_;
    my ($p1, $p2, $p3) = ($points->[0], $points->[1], $points->[2]);

    my $U = [
        $p2->[0] - $p1->[0],
        $p2->[1] - $p1->[1],
        $p2->[2] - $p1->[2],
    ];
    my $V = [
        $p3->[0] - $p1->[0],
        $p3->[1] - $p1->[1],
        $p3->[2] - $p1->[2],
    ];

    my $N = [
        $U->[1] * $V->[2] - $U->[2] * $V->[1],
        $U->[2] * $V->[0] - $U->[0] * $V->[2],
        $U->[0] * $V->[1] - $U->[1] * $V->[0],
    ];

    my $len = sqrt($N->[0] ** 2 + $N->[1] ** 2 + $N->[2] ** 2);
    if ($len == 0) {
        return [0, 0, 0];
    }

    return [
        $N->[0] / $len,
        $N->[1] / $len,
        $N->[2] / $len,
    ];
}

sub mat4xv3 {
    my ($mat, $vec) = @_;

    my ($a1, $a2, $a3, $a4,
         $b1, $b2, $b3, $b4,
         $c1, $c2, $c3, $c4) = @{$mat};

    my ($u, $v, $z) = @{$vec};

    my $x_new = $a1 * $u + $a2 * $v + $a3 * $z + $a4;
    my $y_new = $b1 * $u + $b2 * $v + $b3 * $z + $b4;
    my $z_new = $c1 * $u + $c2 * $v + $c3 * $z + $c4;

    return ($x_new, $y_new, $z_new);
}

sub mat4determinant {
    my ($mat) = @_;
    my $a00 = $mat->[0];
    my $a01 = $mat->[1];
    my $a02 = $mat->[2];
    my $a03 = $mat->[3];
    my $a10 = $mat->[4];
    my $a11 = $mat->[5];
    my $a12 = $mat->[6];
    my $a13 = $mat->[7];
    my $a20 = $mat->[8];
    my $a21 = $mat->[9];
    my $a22 = $mat->[10];
    my $a23 = $mat->[11];
    my $a30 = $mat->[12];
    my $a31 = $mat->[13];
    my $a32 = $mat->[14];
    my $a33 = $mat->[15];
    my $b00 = $a00 * $a11 - $a01 * $a10;
    my $b01 = $a00 * $a12 - $a02 * $a10;
    my $b02 = $a00 * $a13 - $a03 * $a10;
    my $b03 = $a01 * $a12 - $a02 * $a11;
    my $b04 = $a01 * $a13 - $a03 * $a11;
    my $b05 = $a02 * $a13 - $a03 * $a12;
    my $b06 = $a20 * $a31 - $a21 * $a30;
    my $b07 = $a20 * $a32 - $a22 * $a30;
    my $b08 = $a20 * $a33 - $a23 * $a30;
    my $b09 = $a21 * $a32 - $a22 * $a31;
    my $b10 = $a21 * $a33 - $a23 * $a31;
    my $b11 = $a22 * $a33 - $a23 * $a32;
    return $b00 * $b11 - $b01 * $b10 + $b02 * $b09 + $b03 * $b08 - $b04 * $b07 + $b05 * $b06;
}

sub _transvec {
    my ($mm_per_ldu, $scale, $vec) = @_;
    return [map {sprintf('%0.4f', $_ * $mm_per_ldu * $scale)} @{$vec}];
}

sub to_stl {
    my ($self) = @_;

    my $scale = $self->scale || 1;
    my $mm_per_ldu = $self->mm_per_ldu;

    my $stl = "";
    $stl .= "solid GiantLegoRocks\n";

    for my $triangle (@{$self->{triangles}}) {
        my ($p1, $p2, $p3) = map {_transvec($mm_per_ldu, $scale, $_)} @{$triangle};
        my $n = $self->calc_surface_normal([$p1, $p2, $p3]);
        $stl .= "facet normal " . join(' ', map {sprintf('%0.4f', $_)} @{$n}) . "\n";
        $stl .= "    outer loop\n";
        for my $vec (($p1, $p2, $p3)) {
            $stl .= "        vertex " . join(' ', map {sprintf('%0.4f', $_)} @{$vec}) . "\n";
        }
        $stl .= "    endloop\n";
        $stl .= "endfacet\n";
    }

    $stl .= "endsolid GiantLegoRocks\n";

    return $stl;
}

sub stl_buffer {
    my ($self) = @_;

    my $scale = $self->scale || 1;
    my $mm_per_ldu = $self->mm_per_ldu;

    my @facets;
    for my $triangle (@{$self->{triangles}}) {
        my ($p1, $p2, $p3) = map {_transvec($mm_per_ldu, $scale, $_)} @{$triangle};
        my $n = $self->calc_surface_normal([$p1, $p2, $p3]);
        my $facet = {
            normal => [map {sprintf('%0.4f', $_)} @{$n}],
            vertexes => [],
        };
        for my $vec (($p1, $p2, $p3)) {
            push @{$facet->{vertexes}}, map {sprintf('%0.4f', $_)} @{$vec};
        }
        push @facets, $facet;
    }
    return \@facets;
}

sub gl_buffer {
    my ($self) = @_;

    my $scale = $self->scale || 1;
    my $mm_per_ldu = $self->mm_per_ldu;

    my @normals;
    my @vertexes;
    for my $triangle (@{$self->{triangles}}) {
        my ($p1, $p2, $p3) = map {_transvec($mm_per_ldu, $scale, $_)} @{$triangle};
        my $n = $self->calc_surface_normal([$p1, $p2, $p3]);
        my @vertnorms = map {sprintf('%0.4f', $_)} @{$n};
        # OpenGL requires an identical normal for each of the 3 vertexes in the triangle
        # (usually anyway). We won't bother generating indexes, because this should be
        # rendered using `glDrawArrays(GL_TRIANGLES, 0, n)`.
        push @normals, @vertnorms;
        push @normals, @vertnorms;
        push @normals, @vertnorms;
        for my $vec (($p1, $p2, $p3)) {
            push @vertexes, map {sprintf('%0.4f', $_)} @{$vec};
        }
    }
    return {
        normals => \@normals,
        vertexes => \@vertexes,
    };
}

1;
