#!/usr/bin/env perl

our $CRLF = "\r\n";
our $CGIDefaultHeader = "Conent-Type: text/plain$CRLF$CRLF";
our %_GET;
our %_POST;
our %_REQUEST;
our $HTTP_AUTH_USER;
our $HTTP_AUTH_PW;
our @ACCEPT_PREFERENCE;


sub kvPairs
{
	my $_ = shift;
	my %H;
	while(/(\S+)=[""](.*?)[""]/) {
		$H{$1} = $2;
		$_ = $';
	}
	return \%H;
}

sub htmlentities
{
	my $_ = shift;
	s/&/&amp;/g;
	s/</&lt;/g;
	s/>/&gt;/g;
	s/[""]/&quot;/g;
	s/['']/&apos;/g;
	return $_;
}

sub urldecode
{
	my $_ = shift;
	s/\%([A-F0-9]{2})/pack('C', hex $1)/iseg;
	return $_;
}

sub urlencode
{
	my $_ = shift;
	s/([^a-zA-Z0-9_\.-])/sprintf("%%%02X", ord $1)/eg;
	return $_;
}

sub media_range_sorter
{
	my $h = {a=>\%{$_[0]}, b=>\%{$_[1]}};
	my %i = (a => 0, b => 0);
	for my $c ('a', 'b')
	{
		if($h->{$c}->{type} eq '*')			# */*
		{
			$i{$c} = 3;
		}
		elsif($h->{$c}->{subtype} eq '*')	# image/*
		{
			$i{$c} = 2;
		}
		elsif(keys $h->{$c}->{parameters})	# image/png;level=1
		{
			$i{$c} = 0;
		}
		else								# image/png
		{
			$i{$c} = 1;
		}
	}
	return $i{a}<=>$i{b};
}

sub parse_media_spec
{
	my %return;
	for my $str (split /\s*;\s*/, $_[0])
	{
		if($str =~ /^(\S+)=(.*)$/)
		{
			$return{parameters}->{$1} = $2;
		}
		elsif($str =~ /^(.*)\/(.*)$/)
		{
			$return{type} = $1;
			$return{subtype} = $2;
		}
	}
	return \%return;
}

sub most_acceptable
{
	my $offer = $_[0];
	my @offer;
	if(ref $offer eq 'ARRAY')
	{
		@offer = @$offer;
	}
	elsif(ref $offer eq '')
	{
		@offer = split /\s*,\s*/, $offer;
	}
	else
	{
		# FIXME
		return undef;
	}
	my @accept = @{$_[1]} || @ACCEPT_PREFERENCE;
	@offer = map { ref $_ eq '' ? parse_media_spec($_) : $_ } @offer;
	
	for my $offer (@offer)
	{
		for my $accept (@accept)
		{
			if($accept->{type} eq '*' and $accept->{subtype} eq '*')
			{
				$accept->{rank} = 1;
			}
			elsif($accept->{type} eq $offer->{type} and $accept->{subtype} eq '*')
			{
				$accept->{rank} = 2;
			}
			elsif($accept->{type} eq $offer->{type} and $accept->{subtype} eq $offer->{subtype})
			{
				my $prms_match = 0;
				for my $prm_key (keys $accept->{parameters})
				{
					if(defined $offer->{parameters}->{$prm_key})
					{
						if($accept->{parameters}->{$prm_key} eq $offer->{parameters}->{$prm_key})
						{
							$prms_match++
						}
						else
						{
							# $accept->{rank} = 0;
							$prms_match = -3;
							last;
						}
					}
				}
				$accept->{rank} = 3 + $prms_match;
			}
			else
			{
				$accept->{rank} = 0;
			}
		}
		#print STDERR Dumper \@accept;
		my $n = 0;
		my %accept = map { $n++ => $_ } @accept;
		($offer->{preference}) = (sort { $accept{$b}->{rank} <=> $accept{$a}->{rank} } grep { $accept{$_}->{rank} > 0 } keys %accept);
	}

	#print STDERR Dumper \@offer;
	my ($return) = (sort { $a->{preference} <=> $b->{preference} } grep { defined $_->{preference} } @offer);
	return $return;
}


# parse GET parameters
for(split /&/, $ENV{'QUERY_STRING'})
{
	if(my ($prm, $val) = /^([^=]*)=?(.*)$/)
	{
		$val =~ s/\+/ /g;
		$val =~ s/&amp;/&/g;
		$val =~ s/\%([A-F0-9]{2})/pack('C', hex $1)/iseg;
		$_GET{$prm} = $val;
	}
}

# parse POST parameters
if(!-t 0)
{
	local $/ = undef;
	for(split/&/, <STDIN>)
	{
		if(my ($prm, $val) = /^([^=]*)=?(.*)$/)
		{
			$val =~ s/\+/ /g;
			$val =~ s/&amp;/&/g;
			$val = urldecode $val;
			$_POST{$prm} = $val;
		}
	}
}

# initiate REQUEST hash
%_REQUEST = %_POST;
# GET params take precedence over POST ones in REQUEST hash
$_REQUEST{$_} = $_GET{$_} for keys %_GET;



# parse Accept header
my %ACCEPT_PREFERENCE;
for my $media_spec (split /\s*,\s*/, $ENV{'HTTP_ACCEPT'})
{
	my $type;
	my $subtype;
	my %prm;
	my $media = parse_media_spec($media_spec);
	if(defined $media->{type})
	{
		push @{$ACCEPT_PREFERENCE{defined($media->{parameters}->{'q'}) ? $media->{parameters}->{'q'} : 1}}, $media;
	}
}
if(not keys %ACCEPT_PREFERENCE)
{
	# missing (or invalid) Accept header means client accepts all (*/*) media types
	push @{$ACCEPT_PREFERENCE{1}}, parse_media_spec("*/*");
}
for my $quality (reverse sort keys %ACCEPT_PREFERENCE)
{
	push @ACCEPT_PREFERENCE, sort {media_range_sorter($a, $b)} @{$ACCEPT_PREFERENCE{$quality}};
}
undef %ACCEPT_PREFERENCE;



# HTTP Basic Authentication
if($ENV{'HTTP_AUTHORIZATION'} =~ /^Basic\s+([a-zA-Z0-9\/+]+=*)$/)
{
	($HTTP_AUTH_USER, $HTTP_AUTH_PW) = (decode_base64($1) =~ /^([^:]*):(.*)$/);
}


$|++;
select STDERR;
$|++;
select STDOUT;

1;

