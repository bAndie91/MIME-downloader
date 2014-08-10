#!/usr/bin/env perl

use Net::IMAP::Client;
use Email::MIME::Encodings;
use Encode qw/encode decode/;
use URI::Escape;
use Encode::IMAPUTF7;
use MIME::Base64;
use Date::Parse;
use POSIX qw/mktime/;
use Data::Dumper;
use Switch;
use warnings;
use utf8;
binmode STDOUT, ':utf8';

# ==============================

$text_nosubject = "no_subject";

if(defined $ENV{'FCGI_ROLE'})
{
	require "cgi.pl";
	$text_morethanone = "Found more than one files:<br/>
<style>
	table { border-collapse: collapse; }
	td { border: 1px solid lightgray; white-space: nowrap; }
</style>
";
}
else
{
	while(my $opt = shift @ARGV)
	{
		if($opt eq '--help')
		{
			print "Options:
  --server <STR>      IMAP server address
  --filename <STR>    attachment name
  --folder <STR>      IMAP folder name to search in
  --date <STR>        format: \"YYYY-mm-dd_HHMMSS\", you can omit any parts from right
  --uid <INT>         email UID in folder
  --message-id <STR>  filter by substring of Message-ID
  --subject <STR>     filter by substring of Subject
  --part-id <STR>     MIME part ID (eg. \"1.2\")
  --mime <STR>        filder by MIME type (type/subtype)
  --stdout            print data to STDOUT instead of file
  --raw               download full Email with headers
Environments:
  IMAP_LOGIN          format: \"username\@domain:password\"
";
			exit;
		}
		if($opt =~ /^--(stdout|raw)$/)
		{
			$_GET{$1} = 1;
		}
		elsif($opt =~ /^--(server|filename|folder|date|uid|message-id|subject|part-id|mime)$/)
		{
			my $k = $1;
			$k =~ s/-/_/g;
			$_GET{$k} = shift @ARGV;
		}
		else
		{
			die "$0: Invalid parameter: $opt";
		}
	}
}

# ==============================

sub file_put_contents
{
        open my $fh, '>>', $_[0];
        print $fh $_[1]."\n";
        close $fh;
}

sub quotesafe
{
	my $_ = shift;
	s/[^\x20-\x7E]//g;
	s/[""]//g;
	return $_;
}

sub hc
{
	# header case
	my $_ = shift;
	s/[^-]*/\L\u$&/g;
	return $_;
}

sub sprintcsv
{
	my $o = shift;
	my $sep = $o->{separator} || ';';
	my $enc = $o->{enclosure} || '"';
	my $trm = $o->{terminator} || "\n";
	my $nul = $o->{null} || "";
	my @line;
	for my $val (@_)
	{
		$val = $nul if not defined $val;
		if(index($val, $enc)>=0)
		{
			$val =~ s/\Q$enc\E/$&$&/g;
		}
		if(index($val, $sep)>=0)
		{
			$val = $enc.$val.$enc;
		}
		# FIXME # if(index($val, $trm)>=0)
		push @line, $val;
	}
	return join($sep, @line).$trm;
}

sub get_parts_recursive
{
	my $msg = shift;
	my @return;
	if(defined $msg->{parts})
	{
		for my $partobj (@{$msg->{parts}})
		{
			if(defined $partobj->{type} and defined $partobj->{subtype})
			{
				my $name;
				for my $str ($partobj->{parameters}->{name}, $partobj->{disposition}->{attachment}->{filename}, $partobj->{description})
				{
					if(defined $str)
					{
						$name = $str;
						last;
					}
				}
				my $part = {
					mime => $partobj->{type}.'/'.$partobj->{subtype},
					id => $partobj->{part_id},
					cte => $partobj->{transfer_encoding},
					name => $name,
				};
				push @return, $part;
			}
			push @return, get_parts_recursive($partobj);
		}
	}
	return @return;
}

sub finish
{
	my $status_code = int shift;
	my $text = shift || "";
	my $extra_hdrs = shift || {};
	if(defined $ENV{'FCGI_ROLE'})
	{
		print "Status: $status_code$CRLF";
		print $_.": ".$extra_hdrs->{$_}.$CRLF for keys $extra_hdrs;
		print $CRLF;
		print $text;
		exit;
	}
	else
	{
		$text =~ s/\n?$/\n/s;
		print $text;
		exit($status_code>=300 ? 1 : 0);
	}
}

sub rawprint
{
	binmode STDOUT, ':raw';
	print @_;
	binmode STDOUT, ':utf8';
}

# ==============================



# connect to server

if(not(defined $_GET{server} and $_GET{server}=~/^[a-z0-9\.-]+$/i))
{
	finish(404, "No IMAP server given or invalid.");
}
$imap = Net::IMAP::Client->new(
	server => $_GET{server},
	ssl => 1,
	ssl_verify_peer => 1,
	ssl_ca_path => '/etc/ssl/certs',
) or finish(500, "Could not connect to ".$_GET{server}.", $!");


# check credentials and login

if(defined $ENV{'FCGI_ROLE'})
{
	if(defined $HTTP_AUTH_USER and defined $HTTP_AUTH_PW)
	{
		$IMAP_USER = $HTTP_AUTH_USER;
		$IMAP_PW = $HTTP_AUTH_PW;
	}
	else
	{
		finish(401, "No Username or Password given.", {'WWW-Authenticate' => "Basic realm=\"IMAP LOGIN on ".$_GET{server}."\""});
	}
}
else
{
	if(defined $ENV{'IMAP_LOGIN'} and $ENV{'IMAP_LOGIN'} =~ /^(.*?):(.*)$/)
	{
		$IMAP_USER = $1;
		$IMAP_PW = $2;
	}
	else
	{
		die "No credentials in environment: IMAP_LOGIN\n";
	}
}
$imap->login($IMAP_USER, $IMAP_PW) or finish(403, $imap->last_error);



# evaluate criteria

if(defined $_GET{folder})
{
	@Folders = encode('IMAP-UTF-7', decode('utf8', $_GET{folder}));
}
else
{
	@Folders = @{$imap->folders};
}

if(defined $_GET{date})
{
	if(not $_GET{date} =~ /^(?'year'\d\d\d\d)(?:-(?'month'\d\d)(?:-(?'day'\d\d)(?:_(?'hour'\d\d)(?:(?'min'\d\d)(?:(?'sec'\d\d))?)?)?)?)?$/)
	{
		finish(500, "Invalid date format.");
	}
	$search_time_start = mktime($+{sec} || 0, $+{min} || 0, $+{hour} || 0, $+{day} || 1, ($+{month} || 1)-1, $+{year}-1900);
	my %dt = %+;
	if(not defined $dt{sec}) {
		$dt{sec} = 0;
		if(not defined $dt{min}) {
			$dt{min} = 0;
			if(not defined $dt{hour}) {
				$dt{hour} = 0;
				if(not defined $dt{day}) {
					$dt{day} = 1;
					if(not defined $dt{month}) {
						$dt{month} = 1;
						$dt{year}++;
					}
					else {
						$dt{month}++;
					}
				}
				else {
					$dt{day}++;
				}
			}
			else {
				$dt{hour}++;
			}
		}
		else {
			$dt{min}++;
		}
	}
	else {
		$dt{sec}++;
	}
	$search_time_stop = mktime($dt{sec}, $dt{min}, $dt{hour}, $dt{day}, $dt{month}-1, $dt{year}-1900);
}



# search requested attachment

my @Found;

for my $Folder (@Folders)
{
	$imap->select($Folder) or finish(500, $imap->last_error);
	
	for my $Msg (@{$imap->get_summaries($_GET{uid} || '1:*')})
	{
		my $timestamp = str2time($Msg->{internaldate});
		my $messageid = $Msg->{message_id};
		my $found = {
			folder => $Folder,
			uid => $Msg->{uid},
			message_id => $Msg->{message_id},
			date => $Msg->{internaldate},
			subject => decode('MIME-Header', $Msg->{subject}),
		};
		my @Parts = get_parts_recursive($Msg);

		if(
		   (defined $_GET{message_id} and $messageid =~ /\Q$_GET{message_id}\E/i) or
		   (defined $search_time_start and ($timestamp >= $search_time_start and $timestamp < $search_time_stop)) or
		   (defined $_GET{uid} and $_GET{uid} == $Msg->{uid}) or
		   (defined $_GET{subject} and defined $found->{subject} and encode('utf8', $found->{subject}) =~ /\Q$_GET{subject}\E/i) or
		   (not(defined $_GET{message_id} or defined $search_time_start or defined $_GET{uid} or defined $_GET{subject}))
		  )
		{
			if($_GET{raw})
			{
				my %fnd = %$found;
				push @Found, \%fnd;
			}
			else
			{
				for my $part (@Parts)
				{
					if(
					   (defined $_GET{filename} and defined $part->{name} and $part->{name} eq $_GET{filename}) or
					   (defined $_GET{part_id} and $_GET{part_id} eq $part->{id}) or
					   (defined $_GET{mime} and $_GET{mime} eq $part->{mime}) or
					   (not(defined $_GET{filename} or defined $_GET{part_id} or defined $_GET{mime}))
					  )
					{
						my %fnd = %$found;
						$fnd{part} = $part;
						push @Found, \%fnd;
					}
				}
			}
		}
	}
}


# more than one files
if(scalar @Found > 1)
{
	my $text;
	my $most_acceptable_mime;
	if(defined $ENV{'FCGI_ROLE'})
	{
		my $most_acceptable_media = most_acceptable("text/html,text/csv,text/plain");
		if(not defined $most_acceptable_media)
		{
			finish(406);
		}
		$most_acceptable_mime = $most_acceptable_media->{type}."/".$most_acceptable_media->{subtype};
	}
	else
	{
		$most_acceptable_mime = "text/csv";
	}

	switch($most_acceptable_mime)
	{
		case "text/html"
		{
			$text = $text_morethanone;
			$text .= "<table>\n";
			my $prev_msgid;
			for my $fnd (@Found)
			{
				my $same = (defined $prev_msgid and defined $fnd->{message_id} and $fnd->{message_id} eq $prev_msgid);
				my $foldername = decode('IMAP-UTF-7', $fnd->{folder});
				my $foldername_uri = uri_escape_utf8($foldername);
				
				$text .= sprintf "<tr><td><span title='%s'>%s</span></td> <td>%s</td> <td>%s</td> <td><a href='?server=%s&folder=%s&uid=%s&part_id=%s'>%s</a></td> <td>%s</td></tr>\n",
					$same ? "&nbsp;" : htmlentities($fnd->{message_id})||"",
					$same ? "&nbsp;" : htmlentities($foldername)."/".$fnd->{uid},
					$same ? "&nbsp;" : $fnd->{date},
					$same ? "&nbsp;" : sprintf("<a href='?server=%s&folder=%s&uid=%s&raw=1'>%s</a>", $_GET{server}, $foldername_uri, $fnd->{uid}, htmlentities($fnd->{subject})||$text_nosubject),
					$_GET{server}, $foldername_uri, $fnd->{uid}, $fnd->{part}->{id},
					defined $fnd->{part}->{name} ? htmlentities($fnd->{part}->{name}) : "[".$fnd->{part}->{id}."]",
					$fnd->{part}->{mime};
				$prev_msgid = $fnd->{message_id};
			}
			$text .= "</table>\n";
		}
		case ["text/csv", "text/plain"]
		{
			$text = "Folder; UID; Date; Subject; Message-ID; Part ID; Name; MIME type\n";
			for my $fnd (@Found)
			{
				my $foldername = decode('IMAP-UTF-7', $fnd->{folder});
				$text .= sprintcsv({}, $foldername, $fnd->{uid}, $fnd->{date}, $fnd->{subject}, $fnd->{message_id}, $fnd->{part}->{id}, $fnd->{part}->{name}, $fnd->{part}->{mime});
			}
		}
	}

	finish(300, $text, {'Content-Type'=>$most_acceptable_mime});
}

# no files
elsif(scalar @Found == 0)
{
	finish(404, "Not found.");
}

# exactly one file
else
{
	my $fnd = shift @Found;
	my $body_bin;
	my $default_outname = "attachment.dat";

	if($_GET{raw})
	{
		$fnd->{part}->{mime} = 'message/rfc822';
	}
	if(not defined most_acceptable($fnd->{part}->{mime}))
	{
		finish(406);
	}

	$imap->select($fnd->{folder}) or finish(500, $imap->last_error);
	if($_GET{raw})
	{
		$body_bin = ${$imap->get_rfc822_body($fnd->{uid}) or finish(500, $imap->last_error)};
		my $subject_safe = encode('utf8', $fnd->{subject}) || $text_nosubject;
		$subject_safe =~ s{\x00\x23/:}{_}g;
		$default_outname = "$subject_safe.eml";
	}
	else
	{
		my $body_enc = $imap->get_part_body($fnd->{uid}, $fnd->{part}->{id}) or finish(500, $imap->last_error);
		$body_bin = Email::MIME::Encodings::decode($fnd->{part}->{cte}, $$body_enc) or finish(500, $fnd->{part}->{cte}." decode error");
	}
	
	my $outname;
	for my $str ($fnd->{part}->{name}, $default_outname)
	{
		if(defined $str)
		{
			$outname = $str;
			last;
		}
	}
	
	if(defined $ENV{'FCGI_ROLE'})
	{
		printf "Status: 200$CRLF";
		printf "Content-Type: %s$CRLF", $fnd->{part}->{mime};
		printf "Content-Disposition: attachment; filename=\"%s\"$CRLF", quotesafe($outname);
		printf "Content-Length: %d$CRLF", length $body_bin;
		print $CRLF;
		rawprint $body_bin;
	}
	else
	{
		if($_GET{stdout})
		{
			rawprint $body_bin;
		}
		else
		{
			open my $fh, '>', $outname;
			if(print {$fh} $body_bin and close $fh)
			{
				print STDERR "$0: $outname saved.\n";
			}
			else
			{
				die "$!\n";
			}
		}
	}
}

