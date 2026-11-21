<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

## K2s Diagnostics

### Log Collection
<br/>

Usage on a cmd prompt:

```
	k2s system dump
```

Would collect all the required logs to validate if K2s installation is successful.

Final result will be a zip file under C:\var\log\k2s-dump-\<hostname\>-\<datetime\>.zip. 


### Packet capture

<br/>
In order to investigate networking issues, it is necessary to collect traces to better understand the packet flow.

<br />
Usage:

	Go to <installation folder>\debug\

	Start => .\startpacketcapture.cmd
	<Repro the issue>
	Stop  => .\stoppacketcapture.cmd

	After Stopping the trace, use the trace file from c:\server.etl
