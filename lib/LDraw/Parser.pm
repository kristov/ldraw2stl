package LDraw::Parser;

use Moose;

has file => (
    is => 'ro',
    isa => 'Str',
    required => 1,
    documentation => 'The file to parse',
);

has ldraw_path => (
    is => 'ro',
    isa => 'Str',
    default => '/usr/share/ldraw',
    documentation => 'Where to find ldraw files',
);

has scale => (
    is => 'rw',
    isa => 'Num',
    default => 1.0,
    documentation => 'Scale the model',
);

has mm_per_ldu => (
    is => 'rw',
    isa => 'Num',
    default => 0.4,
    documentation => 'Number of mm per LDU (LDraw Unit)',
);

has invert => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    documentation => 'Invert this part',
);

use constant X => 0;
use constant Y => 1;
use constant Z => 2;

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

sub parse_line {
    my ( $self, $line ) = @_;

    $line =~ s/^\s+//;

    if ( $line =~ /^([0-9]+)\s+(.+)$/ ) {
        my ( $line_type, $rest ) = ( $1, $2 );
        if ( $line_type == 0 ) {
            $self->parse_comment_or_meta( $rest );
        }
        elsif ( $line_type == 1 ) {
            $self->parse_sub_file_reference( $rest );
            $self->invert( 0 );
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
            warn "unhandled line type: $line_type";
        }
    }
}

sub parse_comment_or_meta {
    my ( $self, $rest ) = @_;

    my @items = split( /\s+/, $rest );
    my $first = shift @items;

    if ( $first && $first eq 'BFC' ) {
        $self->handle_bfc_command( @items );
    }
}

sub handle_bfc_command {
    my ( $self, @items ) = @_;

    my $first = shift @items;

    if ( $first && $first eq 'INVERTNEXT' ) {
        $self->invert( 1 );
    }
}

sub parse_sub_file_reference {
    my ( $self, $rest ) = @_;
    # 16 0 -10 0 9 0 0 0 1 0 0 0 -9 2-4edge.dat
    my @items = split( /\s+/, $rest );
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

#    / a d g 0 \   / a b c x \
#    | b e h 0 |   | d e f y |
#    | c f i 0 |   | g h i z |
#    \ x y z 1 /   \ 0 0 0 1 /

    my $mat = [
        $a, $b, $c, $x,
        $d, $e, $f, $y,
        $g, $h, $i, $z,
        0, 0, 0, 1,
    ];

    if ( scalar( @items ) != 1 ) {
        warn "um, filename is made up of multiple parts (or none)";
    }

    my $filename = lc( $items[0] );
    $filename =~ s/\\/\//g;

    my $p_filename = join( '/', $self->ldraw_path, 'p', $filename );
    my $hires_filename = join( '/', $self->ldraw_path, 'p/48', $filename );
    my $parts_filename = join( '/', $self->ldraw_path, 'parts', $filename );
    my $models_filename = join( '/', $self->ldraw_path, 'models', $filename );

    my $subpart_filename;
    if ( -e $hires_filename ) {
        $subpart_filename = $hires_filename;
    }
    elsif ( -e $p_filename ) {
        $subpart_filename = $p_filename;
    }
    elsif (-e $parts_filename ) {
        $subpart_filename = $parts_filename;
    }
    elsif ( -e $models_filename ) {
        $subpart_filename = $models_filename;
    }
    else {
        warn "unable to find file: $filename in normal paths";
        return;
    }

    my $subparser = __PACKAGE__->new( {
        file       => $subpart_filename,
        ldraw_path => $self->ldraw_path,
        invert     => $self->invert,
    } );
    $subparser->parse;

    for my $triangle ( @{ $subparser->{triangles} } ) {
        for my $vec ( @{ $triangle } ) {
            my @new_vec = max4xv3( $mat, $vec );
            $vec->[0] = $new_vec[0];
            $vec->[1] = $new_vec[1];
            $vec->[2] = $new_vec[2];
        }
        push @{ $self->{triangles} }, $triangle;
    }
}

sub parse_line_command {
    my ( $self, $rest ) = @_;
}

sub parse_triange_command {
    my ( $self, $rest ) = @_;
    # 16 8.9 -10 58.73 6.36 -10 53.64 9 -10 55.5
    my @items = split( /\s+/, $rest );
    my $color = shift @items;
    my $p1 = [ $items[0], $items[1], $items[2] ];
    my $p2 = [ $items[3], $items[4], $items[5] ];
    my $p3 = [ $items[6], $items[7], $items[8] ];
    my $n = [ $self->calc_surface_normal( $p1, $p2, $p3 ) ];
    push @{ $self->{triangles} }, [ $p1, $p2, $p3, $n ];
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
    my $na = [ $self->calc_surface_normal( [ $x1, $y1, $z1 ], [ $x2, $y2, $z2 ], [ $x3, $y3, $z3 ] ) ];
    my $nb = [ $self->calc_surface_normal( [ $x3, $y3, $z3 ], [ $x4, $y4, $z4 ], [ $x1, $y1, $z1 ] ) ];
    push @{ $self->{triangles} }, [
        [ $x1, $y1, $z1 ],
        [ $x2, $y2, $z2 ],
        [ $x3, $y3, $z3 ],
        $na,
    ];
    push @{ $self->{triangles} }, [
        [ $x3, $y3, $z3 ],
        [ $x4, $y4, $z4 ],
        [ $x1, $y1, $z1 ],
        $nb,
    ];
}

sub WTF_parse_quadrilateral_command {
    my ( $self, $rest ) = @_;
    # 16 1.27 10 68.9 -6.363 10 66.363 10.6 10 79.2 7.1 10 73.27
    my @items = split( /\s+/, $rest );
    my $color = shift @items;
    my $p1 = [ $items[0], $items[1], $items[2] ];
    my $p2 = [ $items[3], $items[4], $items[5] ];
    my $p3 = [ $items[6], $items[7], $items[8] ];
    my $p4 = [ $items[9], $items[10], $items[11] ];
    my $na = [ $self->calc_surface_normal( $p1, $p2, $p3 ) ];
    my $nb = [ $self->calc_surface_normal( $p3, $p4, $p1 ) ];
    push @{ $self->{triangles} }, [ $p1, $p2, $p3, $na ];
    push @{ $self->{triangles} }, [ $p3, $p4, $p1, $nb ];
}

sub parse_optional {
    my ( $self, $rest ) = @_;
}

sub calc_surface_normal {
    my ( $self, $ip1, $ip2, $ip3 ) = @_;

    my ( $p1, $p2, $p3 ) = ( $ip1, $ip2, $ip3 );
    if ( $self->invert ) {
        ( $p1, $p2, $p3 ) = ( $ip1, $ip3, $ip2 );
    }

    my ( $N, $U, $V ) = ( [], [], [] );

    $U->[X] = $p2->[X] - $p1->[X];
    $U->[Y] = $p2->[Y] - $p1->[Y];
    $U->[Z] = $p2->[Z] - $p1->[Z];

    $V->[X] = $p3->[X] - $p1->[X];
    $V->[Y] = $p3->[Y] - $p1->[Y];
    $V->[Z] = $p3->[Z] - $p1->[Z];

    $N->[X] = $U->[Y] * $V->[Z] - $U->[Z] * $V->[Y];
    $N->[Y] = $U->[Z] * $V->[X] - $U->[X] * $V->[Z];
    $N->[Z] = $U->[X] * $V->[Y] - $U->[Y] * $V->[X];

    return ( $N->[X], $N->[Y], $N->[Z] );
}

sub max4xv3 {
    my ( $mat, $vec ) = @_;

    my ( $a1, $a2, $a3, $a4,
         $b1, $b2, $b3, $b4,
         $c1, $c2, $c3, $c4 ) = @{ $mat };

    my ( $x_old, $y_old, $z_old ) = @{ $vec };

    my $x_new = $a1 * $x_old + $a2 * $y_old + $a3 * $z_old + $a4;
    my $y_new = $b1 * $x_old + $b2 * $y_old + $b3 * $z_old + $b4;
    my $z_new = $c1 * $x_old + $c2 * $y_old + $c3 * $z_old + $c4;

    return ( $x_new, $y_new, $z_new );
}

sub to_stl {
    my ( $self ) = @_;

    my $scale = $self->scale || 1;
    my $mm_per_ldu = $self->mm_per_ldu;

    my $stl = "";
    $stl .= "solid GiantLegoRocks\n";

    for my $triangle ( @{ $self->{triangles} } ) {
        my ( $p1, $p2, $p3, $n ) = @{ $triangle };
        $stl .= "facet normal " . join( ' ', map { sprintf( '%0.4f', $_ ) } @{ $n } ) . "\n";
        $stl .= "    outer loop\n";
        for my $vec ( ( $p1, $p2, $p3 ) ) {
            my @transvec = map { sprintf( '%0.4f', $_ ) } map { $_ * $mm_per_ldu * $scale } @{ $vec };
            $stl .= "        vertex " . join( ' ', @transvec ) . "\n";
        }
        $stl .= "    endloop\n";
        $stl .= "endfacet\n";
    }

    $stl .= "endsolid GiantLegoRocks\n";

    return $stl;
}

1;
