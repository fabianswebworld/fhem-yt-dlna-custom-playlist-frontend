# fhem-yt-dlna-custom-playlist-frontend
Small helper module for FHEM. Generates dynamic JSON playlists (Custom Playlists) for yt-dlna from FHEM readings. Makes it possible to control your FHEM Home Automation system via the media menu of your UPnP/DLNA client.

### 98_ytdlnaCustomPlaylistFrontend.pm

This module reads a JSON file (template), processes tokens like `{Device:Reading:Property|Default}`, generates FHEM command URLs and writes the result back to the file. It is designed to work with the **yt-dlna** UPnP server to provide a dynamic DLNA folder structure.  
  
(A running installation of [yt-dlna](https://github.com/fabianswebworld/yt-dlna), ideally on the same host as the FHEM instance, is required.)  
  
#### Define

`define <name> ytdlnaCustomPlaylistFrontend`  

#### Set

*   `set <name> update`  
    Triggers a manual update of the playlist file.

#### Tokens & Syntax

The module searches for `fhem_title` and `fhem_cmd` keys in your JSON file and replaces tokens in the format: `{DEVICE:READING[:[PROPERTY][[,]PARAMS]][|DEFAULT]}`

*   **DEVICE**: FHEM device name.
*   **READING**: Reading name (default: state).
*   **PROPERTY**:
    *   `value`: The reading's value (default if PROPERTY is omitted).
    *   `time`: The timestamp of the reading.
    *   `update`: The time of the current playlist update.
*   **PARAMS**: Format depends on PROPERTY.
    *   For 'value': **n,d** (n = number of places after decimal separator, d = decimal separator: d=dot, c=comma)
    *   For 'time': **format** (format = format string for date/time, e.g. %H:%M, overrides the value set in attribute "timestamp\_format")
*   **DEFAULT**: Optional fallback if the device/reading is not found.

Examples:

*   {Lamp:state} (same as {Lamp:state:value})
*   {Lamp:state:time}
*   {Sensor:temp:1,c} (same as {Sensor:temp:value,1,c})
*   {Sensor:temp:time,%H:%M}

The name of the playlist entry is generated based on the template provided in the JSON key `fhem_title` by replacing the contained tokens. The entry's URL is constructed using the relevant device attributes (FHEM host, port, and CSRF token) in combination with the command specified in the `fhem_cmd` JSON key for that specific entry.

#### Attributes

*   `playlist_file`: Full path to the .json file (mandatory).
*   `playlist_update_interval`: Update interval in seconds (default: 60, min: 10).
*   `fhem_instance_host`: Hostname for generated URLs (default: localhost).
*   `fhem_instance_port`: Port for generated URLs (default: 8083).
*   `fhem_fwcsrf`: FWCSRF token for FHEM commands.
*   `fhem_additional_parameters`: Additional GET-Parameters for FHEM URL.
*   `timestamp_format`: POSIX strftime format for the `update` property (default: %Y-%m-%d %H:%M:%S).
*   `default_value`: Global fallback if no token-specific default is provided.
*   `replace_list`: String in format _replace,with|replace,with..._ which will be appliced when formatting the readings.
