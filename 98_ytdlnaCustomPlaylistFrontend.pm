# ==============================================================================
# 98_ytdlnaCustomPlaylistFrontend.pm
# Generates dynamic JSON playlists for yt-dlna from FHEM readings
#
# Version: 1.0.1 (2026-08-21)
#
# Copyright (c) 2026 Fabian Schneider (@fabianswebworld) and contributors
# Licensed under the MIT License - see LICENSE file for details.
# ==============================================================================

package main;

use strict;
use warnings;
use JSON;            
use Fcntl qw(:flock); 
use HttpUtils;       
use POSIX qw(strftime);

sub ytdlnaCustomPlaylistFrontend_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}    = "ytdlnaCustomPlaylistFrontend_Define";
    $hash->{UndefFn}  = "ytdlnaCustomPlaylistFrontend_Undefine";
    $hash->{SetFn}    = "ytdlnaCustomPlaylistFrontend_Set";
    $hash->{AttrList} = "fhem_instance_host " .
                        "fhem_instance_port " .
                        "fhem_fwcsrf " .
                        "fhem_additional_parameters " .
                        "playlist_file " .
                        "playlist_update_interval " .
                        "timestamp_format " .
                        "default_value " .
                        "replace_list " .
                        $readingFnAttributes;

    $hash->{NOTIFYDEV} = "global";
}

sub ytdlnaCustomPlaylistFrontend_Define {
    my ($hash, $def) = @_;
    $hash->{STATE} = "Initialized";
    $hash->{HELPER}{LAST_UPDATE} = time();
    
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 5, "ytdlnaCustomPlaylistFrontend_Timer", $hash, 0);
    return undef;
}

sub ytdlnaCustomPlaylistFrontend_Undefine {
    my ($hash) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

sub ytdlnaCustomPlaylistFrontend_Set {
    my ($hash, @a) = @_;
    my $cmd  = $a[1];

    if($cmd eq "update") {
        ytdlnaCustomPlaylistFrontend_UpdateFile($hash);
        return "Playlist update triggered manually.";
    }
    return "Unknown argument $cmd, choose one of update:noArg";
}

sub ytdlnaCustomPlaylistFrontend_Timer {
    my ($hash) = @_;
    ytdlnaCustomPlaylistFrontend_UpdateFile($hash);
    my $interval = AttrVal($hash->{NAME}, "playlist_update_interval", 60);
    $interval = 10 if ($interval < 10); 
    InternalTimer(gettimeofday() + $interval, "ytdlnaCustomPlaylistFrontend_Timer", $hash, 0);
}

sub ytdlnaCustomPlaylistFrontend_UpdateFile {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $file = AttrVal($name, "playlist_file", undef);

    if (!$file || !-e $file) {
        readingsSingleUpdate($hash, "state", "Error: Playlist file not found", 1);
        return;
    }

    if (open(my $fh, "+<", $file)) {
        flock($fh, LOCK_EX) or Log3 $name, 2, "$name: Could not lock file $file";
        
        local $/;
        my $content = <$fh>;
        
        if ($content) {
            eval {
                my $data = decode_json($content);
                
                $hash->{HELPER}{LAST_UPDATE} //= time();
                
                ytdlnaCustomPlaylistFrontend_ProcessNodes($hash, $data);
                
                # intermediate step: new json with old update timestamps
                my $json_out = JSON->new->utf8->pretty->encode($data);
                
                # compare contents to avoid unnecessary writes
                my $old_cmp = $content;
                my $new_cmp = $json_out;
                $old_cmp =~ s/^\s+|\s+$//g;
                $new_cmp =~ s/^\s+|\s+$//g;
                
                if ($old_cmp eq $new_cmp) {
                    Log3 $name, 4, "$name: No changes detected, skipping write operation.";
                    readingsSingleUpdate($hash, "state", "Update skipped (no changes)", 1);
                } else {
                    $hash->{HELPER}{LAST_UPDATE} = time();
                    
                    ytdlnaCustomPlaylistFrontend_ProcessNodes($hash, $data);
                    $json_out = JSON->new->utf8->pretty->encode($data);
                    
                    seek($fh, 0, 0);
                    truncate($fh, 0);
                    print $fh $json_out;
                    
                    readingsSingleUpdate($hash, "state", "Updated " . localtime(), 1);
                    Log3 $name, 4, "$name: Changes detected, playlist file updated.";
                }
            };
            if ($@) {
                Log3 $name, 2, "$name: JSON Error: $@";
                readingsSingleUpdate($hash, "state", "Error: invalid json", 1);
            }
        }
        close($fh);
    }
}

sub ytdlnaCustomPlaylistFrontend_ProcessNodes {
    my ($hash, $node) = @_;

    if (ref($node) eq 'HASH') {
        if (exists $node->{fhem_title} && $node->{fhem_title} ne "") {
            $node->{name} = ytdlnaCustomPlaylistFrontend_ReplaceTokens($hash, $node->{fhem_title});
        }
        if (exists $node->{fhem_cmd} && $node->{fhem_cmd} ne "") {
            $node->{url} = ytdlnaCustomPlaylistFrontend_BuildURL($hash, $node->{fhem_cmd});
        }
        if (exists $node->{children} && ref($node->{children}) eq 'ARRAY') {
            foreach my $child (@{$node->{children}}) {
                ytdlnaCustomPlaylistFrontend_ProcessNodes($hash, $child);
            }
        }
    }
}

sub ytdlnaCustomPlaylistFrontend_TokenCallback {
    my ($hash, $dev, $read, $prop_str, $dflt_val) = @_;
    
    my $name = $hash->{NAME};
    my $reading = (defined($read) && $read ne "") ? $read : "state";
    my $fallback = $dflt_val // AttrVal($name, "default_value", "n/a");
    my $ts_global_format = AttrVal($name, "timestamp_format", "%Y-%m-%d %H:%M:%S");

    # trim input
    $dev =~ s/^\s+|\s+$//g if $dev;
    $reading =~ s/^\s+|\s+$//g if $reading;
    
    # parse property and sub-parameters
    my @params = split(',', $prop_str // "");
    my $prop = shift @params || "value";
    
    # allow for short form without :value
    if ($prop =~ /^\d+$/) {
        unshift @params, $prop;
        $prop = "value";
    }

    my $ret = $fallback;

    if ($prop eq "value") {
        $ret = ReadingsVal($dev, $reading, $fallback);
        
        # numeric formatting
        if (@params && $ret =~ /^-?\d+(\.\d+)?$/) {
            my $n = shift @params;
            my $sep = shift @params;
            $ret = sprintf("%.${n}f", $ret);
            $ret =~ s/\./,/g if (defined $sep && $sep eq "c");
        }
        
        # global replacements
        my $repl_list = AttrVal($name, "replace_list", "");
        if ($repl_list ne "") {
            my @pairs = split('\|', $repl_list);
            foreach my $pair (@pairs) {
                my ($old, $new) = split(',', $pair);
                if (defined $old && defined $new && $ret eq $old) {
                    $ret = $new;
                    last;
                }
            }
        }
    } 
    elsif ($prop eq "time") {
        my $ts = ReadingsTimestamp($dev, $reading, "");
        if ($ts ne "") {
            my $fmt = shift @params || $ts_global_format;
            $ret = strftime($fmt, localtime(time_str2num($ts)));
        }
    }
    elsif ($prop eq "update") {
        my $fmt = shift @params || $ts_global_format;
        $ret = strftime($fmt, localtime($hash->{HELPER}{LAST_UPDATE}));
    }

    return $ret;
}

sub ytdlnaCustomPlaylistFrontend_ReplaceTokens {
    my ($hash, $string) = @_;
    return "" if !defined($string);
    $string =~ s/\{([^:|{}]+)(?::([^:|{}]+))?(?::([^:|{}]+))?(?:\|([^|{}]+))?\}/ytdlnaCustomPlaylistFrontend_TokenCallback($hash, $1, $2, $3, $4)/ge;
    return $string;
}

sub ytdlnaCustomPlaylistFrontend_BuildURL {
    my ($hash, $fhem_cmd) = @_;
    my $name = $hash->{NAME};
    my $host   = AttrVal($name, "fhem_instance_host", "localhost");
    my $port   = AttrVal($name, "fhem_instance_port", "8083");
    my $csrf   = AttrVal($name, "fhem_fwcsrf", "");
    my $params = AttrVal($name, "fhem_additional_parameters", "");
    my $encoded_cmd = urlEncode($fhem_cmd);
    my $url = "http://" . $host . ":" . $port . "/fhem?XHR=1&cmd=" . $encoded_cmd;
    $url .= "&fwcsrf=" . $csrf if ($csrf ne "");
    $url .= $params if ($params ne "");
    return $url;
}

1;


=pod
=item helper
=item summary Generate dynamic JSON playlists for yt-dlna from FHEM readings.
=item summary_DE Erzeugt dynamische JSON-Playlisten für yt-dlna aus FHEM-Readings.

=begin html

<a id="ytdlnaCustomPlaylistFrontend"></a>
<h3>ytdlnaCustomPlaylistFrontend</h3>
<ul>
    This module reads a JSON file (template), processes tokens like <code>{Device:Reading:Property|Default}</code>, 
    generates FHEM command URLs and writes the result back to the file. It is designed to work with the 
    <b>yt-dlna</b> UPnP server to provide a dynamic DLNA folder structure.
    <br /><br />
    (A running installation of <a href="https://github.com/fabianswebworld/yt-dlna" target="_blank">yt-dlna</a>, ideally
    on the same host as the FHEM instance, is required.)
    <br /><br />
    <a id="ytdlnaCustomPlaylistFrontend_Define"></a>
    <h4>Define</h4>
    <code>define &lt;name&gt; ytdlnaCustomPlaylistFrontend</code>
    <br /><br />
    <a id="ytdlnaCustomPlaylistFrontend_Set"></a>
    <h4>Set</h4>
    <ul>
        <li><code>set &lt;name&gt; update</code><br>
            Triggers a manual update of the playlist file.</li>
    </ul>

    <a id="ytdlnaCustomPlaylistFrontend_Tokens"></a>
    <h4>Tokens & Syntax</h4>
    The module searches for <code>fhem_title</code> and <code>fhem_cmd</code> keys in your JSON file and replaces tokens in the format:
    <code>{DEVICE:READING[:[PROPERTY][[,]PARAMS]][|DEFAULT]}</code>
    <ul>
        <li><b>DEVICE</b>: FHEM device name.</li>
        <li><b>READING</b>: Reading name (default: state).</li>
        <li><b>PROPERTY</b>: 
            <ul>
                <li><code>value</code>: The reading's value (default if PROPERTY is omitted).</li>
                <li><code>time</code>: The timestamp of the reading.</li>
                <li><code>update</code>: The time of the current playlist update.</li>
            </ul>
        </li>
        <li><b>PARAMS</b>: Format depends on PROPERTY.
            <ul>
                <li>For 'value': <b>n,d</b> (n = number of places after decimal separator, d = decimal separator: d=dot, c=comma)</li>
                <li>For 'time': <b>format</b> (format = format string for date/time, e.g. %H:%M, overrides the value set in attribute "timestamp_format")</li>
            </ul>
        </li>
        <li><b>DEFAULT</b>: Optional fallback if the device/reading is not found.</li>
    </ul>
    Examples:
    <ul>
        <li>{Lamp:state} (same as {Lamp:state:value})</li>
        <li>{Lamp:state:time}</li>
        <li>{Sensor:temp:1,c} (same as {Sensor:temp:value,1,c})</li>
        <li>{Sensor:temp:time,%H:%M}</li>
    </ul>
    The name of the playlist entry is generated based on the template provided in the JSON key <code>fhem_title</code> by
    replacing the contained tokens. The entry's URL is constructed using the relevant device attributes (FHEM host, port, and CSRF token) in
    combination with the command specified in the <code>fhem_cmd</code> JSON key for that specific entry.

    <a id="ytdlnaCustomPlaylistFrontend_Attr"></a>
    <h4>Attributes</h4>
    <ul>
        <li><code>playlist_file</code>: Full path to the .json file (mandatory).</li>
        <li><code>playlist_update_interval</code>: Update interval in seconds (default: 60, min: 10).</li>
        <li><code>fhem_instance_host</code>: Hostname for generated URLs (default: localhost).</li>
        <li><code>fhem_instance_port</code>: Port for generated URLs (default: 8083).</li>
        <li><code>fhem_fwcsrf</code>: FWCSRF token for FHEM commands.</li>
        <li><code>fhem_additional_parameters</code>: Additional GET-Parameters for FHEM URL.</li>
        <li><code>timestamp_format</code>: POSIX strftime format for the <code>update</code> property (default: %Y-%m-%d %H:%M:%S).</li>
        <li><code>default_value</code>: Global fallback if no token-specific default is provided.</li>
        <li><code>replace_list</code>: String in format <i>replace,with|replace,with...</i> which will be appliced when formatting the readings.</li>

    </ul>
</ul>

=end html

=begin html_DE

<a id="ytdlnaCustomPlaylistFrontend_DE"></a>
<h3>ytdlnaCustomPlaylistFrontend (DE)</h3>
<ul>
    Dieses Modul liest eine JSON-Datei ein, ersetzt Platzhalter (Tokens) durch aktuelle FHEM-Werte, 
    erzeugt Steuerungs-URLs und schreibt die Datei wieder zurück. Ideal für den <b>yt-dlna</b> Server, welches Dateien in genau
    diesem Format als sog. "Custom Playlists" erwartet und dann als Ordnerstruktur via UPnP/DLNA bereitstellt.
    <br /><br />
    (Die Installation von <a href="https://github.com/fabianswebworld/yt-dlna" target="_blank">yt-dlna</a>, idealerweise auf
    dem gleichen System wie FHEM, wird vorausgesetzt.)
    <br /><br />
    <a id="ytdlnaCustomPlaylistFrontend_Define_DE"></a>
    <h4>Define</h4>
    <code>define &lt;name&gt; ytdlnaCustomPlaylistFrontend</code>
    <br><br>
    <a id="ytdlnaCustomPlaylistFrontend_Set_DE"></a>
    <h4>Set</h4>
    <ul>
        <li><code>set &lt;name&gt; update</code><br>
            Triggert ein manuelles Update der Datei.</li>
    </ul>

    <a id="ytdlnaCustomPlaylistFrontend_Tokens_DE"></a>
    <h4>Tokens & Syntax</h4>
    Das Modul verarbeitet die Keys <code>fhem_title</code> und <code>fhem_cmd</code> nach dem Schema:<br />
    <code>{DEVICE:READING[:[PROPERTY][[,]PARAMS]][|DEFAULT]}</code>
    <ul>
        <li><b>DEVICE</b>: Name des FHEM-Geräts.</li>
        <li><b>READING</b>: Name des Readings (Standard: state).</li>
        <li><b>PROPERTY</b>: 
            <ul>
                <li><code>value</code>: Der Wert des Readings (Standard, wenn PROPERTY fehlt).</li>
                <li><code>time</code>: Der Zeitstempel des Readings.</li>
                <li><code>update</code>: Der Zeitpunkt des aktuellen Playlist-Updates.</li>
            </ul>
        </li>
        <li><b>PARAMS</b>: Abhängig von PROPERTY.
            <ul>
                <li>Für 'value': <b>n,d</b> (n = Anzahl Nachkommastellen, d = Dezimaltrenner: d=dot, c=comma)</li>
                <li>Für 'time': <b>format</b> (format = Perl-Formatstring für Datum/Zeit, z.B. %H:%M, überschreibt den Wert des Attributs "timestamp_format")</li>
            </ul>
        </li>
        <li><b>DEFAULT</b>: Optionaler Ersatzwert, falls Gerät/Reading nicht existiert.</li>
    </ul>
    Beispiele:
    <ul>
        <li>{Lampe:state} (entspricht {Lampe:state:value})</li>
        <li>{Lampe:state:time}</li>
        <li>{Sensor:temp:1,c} (entspricht {Sensor:temp:value,1,c})</li>
        <li>{Sensor:temp:time,%H:%M}</li>
    </ul>
    Dabei wird der Name des Playlist-Eintrags gemäß der Vorlage aus dem JSON (<code>fhem_title</code>) unter Ersetzung der Tokens generiert. Die URL des Eintrags wird aus den relevanten Attributen (FHEM-Host, Port, CSRF-Token) und der Befehlsangabe im JSON (<code>fhem_cmd</code>) für diesen Eintrag generiert.

    <a id="ytdlnaCustomPlaylistFrontend_Attr_DE"></a>
    <h4>Attribute</h4>
    <ul>
        <li><code>playlist_file</code>: Vollständiger Pfad zur JSON-Datei (Pflicht).</li>
        <li><code>playlist_update_interval</code>: Intervall in Sekunden (Standard: 60).</li>
        <li><code>fhem_instance_host</code>: Hostname für URLs (Standard: localhost).</li>
        <li><code>fhem_instance_port</code>: Port für URLs (Standard: 8083).</li>
        <li><code>fhem_fwcsrf</code>: CSRF-Token für Befehle.</li>
        <li><code>fhem_additional_parameters</code>: Zusätzliche GET-Parameter für die FHEM-URL.</li>
        <li><code>timestamp_format</code>: Datumsformat für <code>update</code> (z.B. %H:%M:%S).</li>
        <li><code>default_value</code>: Standardwert für nicht gefundene Devices/Readings.</li>
        <li><code>replace_list</code>: String im Format <i>suchstring,ersetzung|suchstring,ersetzung...</i> der bei der Ausgabe der Readings angewendet wird (z.B. on,an|off,aus|open,auf|close,zu)</li>

    </ul>
</ul>

=end html_DE

=cut
