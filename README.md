# MEMS Acoustic Emission Acquisition and Source Localization

FPGA-based multichannel acquisition and D1-AIC source localization for MEMS acoustic emission sensor arrays.

This project combines FPGA firmware for synchronous AE event acquisition with Python host software for data reception, visualization, storage, and two-dimensional source localization. The localization pipeline uses first-difference Akaike information criterion (D1-AIC) arrival-time picking and multistart bounded least-squares minimization of arrival-time residuals. It requires no location-labeled training data or model training.

The FPGA handles ADC reception, digital preprocessing, decimation, threshold triggering, event recording, DDR buffering, and UDP transmission. The host computer performs arrival-time picking and coordinate estimation; the current RTL does not implement the complete localization algorithm on the FPGA.

This README describes the inspected `AE_project_final` FPGA project and the host version containing `ae_acq_loc_gui_d1aic.py` and `ae_localization/d1_aic_core.py`. Earlier interfaces and analysis scripts may also be present. Software defaults and manuscript settings are distinguished below. Paths within each component are relative to that component's root directory; run commands from the relevant root.

## Repository Layout and Quick Start

```text
AE_project_final/                      # Vivado project
adc_data_preprocess/                   # Referenced FIR IP
AE0512/AE_Multichannel/                # Referenced FIR coefficients
ae_python_39_acq_loc_multich_gui_english/
  ae_python_39_acq_loc_multich_v6/
    ae_python_39_acq_loc_multich_v6/    # Python application root
```

Open `AE_project_final/AE_project.xpr` in Vivado. The external FIR IP and coefficient dependencies are included in the relative locations referenced by the project; keep these directories together.

For the Python instructions below, first navigate from the repository root to the application directory:

```powershell
cd ae_python_39_acq_loc_multich_gui_english/ae_python_39_acq_loc_multich_v6/ae_python_39_acq_loc_multich_v6
```

Then follow **Environment and Launch**. Use `ae_acq_loc_gui_d1aic.py` for the D1-AIC interface, rather than the legacy `ae_gui.py` entry point.

## Contents

- [Hardware and development environment](#hardware-and-development-environment)
- [Shared network and event protocol](#shared-network-and-event-protocol)
- [Clocks and sampling rates](#clocks-and-sampling-rates)
- [Host software](#host-software)
- [FPGA project](#fpga-project)
- [Experimental configuration and validation scope](#experimental-configuration-and-validation-scope)
- [Release contents and related work](#release-contents-and-related-work)

## Hardware and Development Environment

| Item | Project configuration |
| --- | --- |
| Tool version | Xilinx Vivado 2020.2, as recorded in the XPR |
| FPGA part | `xc7a200tfbg484-2` |
| Synthesis top | `top` |
| Project file | `AE_project.xpr` |
| Top-level RTL | `AE_project.srcs/sources_1/new/top.v` |
| Board pin constraints | `AE_project.srcs/constrs_1/new/demo.xdc` |
| Acquisition hardware | Artix-7 core board, two eight-channel AD9257 ADCs, companion analog conditioning board, and DDR3 |
| Ethernet | RGMII at the external PHY interface; GMII internally on the UDP/MAC side |
| ADC resolution / channels | 14 bits / up to 16 channels |
| Base sample stream | 40 MS/s; decimation sets the effective event sampling rate |
| Event length | 8192 samples per channel: 2048 pre-trigger and 6144 post-trigger |

The manuscript acquisition module consists of three stacked PCBs and measures 10 cm x 6 cm x 5 cm, excluding sensors, cables, and the host computer. Pin assignments and DDR settings are hardware-specific and require adaptation for other boards.

## Shared Network and Event Protocol

| Parameter | Default |
| --- | --- |
| FPGA IPv4 | `192.168.100.234` |
| Host destination IPv4 | `192.168.100.145` |
| FPGA MAC | `12:34:56:78:9A:BC` |
| Destination MAC | Broadcast: `FF:FF:FF:FF:FF:FF` |
| Companion client UDP ports | Local and remote ports both 1234; verify against RTL settings |

Adapt settings to the actual local network. Update the RTL and client together when changing addresses or ports.

The companion protocol uses these identifiers:

- `USND`: a 64-byte host control packet containing sampling-rate codes, channel masks, thresholds, time information, and control flags.
- `SNSR`: a status-information packet.
- `AEUP`: fragmented event information and waveform data.

Byte ordering and layouts differ between packet types. Use the RTL and companion `ae_fpga_client/protocol.py` together as the protocol definition rather than applying one byte order to every field. Event reassembly should check sequence numbers, packet counts, payload offsets, and completeness.

`adc_filter_adc14_to_s16.v` sign-extends 14-bit codes to 16 bits without increasing ADC resolution. The host saves samples in a 16-bit integer container. The manuscript uses `V = code / 8192` for a +/-1 V range; verify this against scaling in the final filtering chain.

The enabled-channel mask is `0x000F` for CH01-CH04 and `0xFFFF` for CH01-CH16.

## Clocks and Sampling Rates

The top level connects system, ADC, Ethernet, and DDR clocks. Source comments identify a 200 MHz system clock, 40 MHz ADC clock, 125 MHz Ethernet transmit reference, and 400 MHz DDR system clock. Confirm final frequencies against the clock IP configurations and implementation reports.

The ADC serial DCLK is distinct from the 40 MHz sample-stream clock. Its XDC period must not be interpreted as the effective per-channel sample interval. `ae_adc_data_downsampler.v` counts valid input samples to produce the decimated stream:

```text
Effective event sampling rate = 40 MHz / sample_rate_div
```

The companion GUI offers factors 1, 2, 4, 8, 16, 20, 40, and 80, corresponding to 40, 20, 10, 5, 2.5, 2, 1, and 0.5 MS/s. The four-channel localization configuration uses factor 40, giving an effective rate of 1 MS/s. Selecting 1 MS/s does not directly change the physical ADC sampling clock to 1 MHz in this implementation.

Evaluate the digital filter response together with the Nyquist frequency after decimation. A fixed filter's name or nominal cutoff does not establish alias-free operation at every selectable rate. Verify the relevant signal bandwidth for each configuration.

## Host Software

- Configure FPGA acquisition parameters over UDP, including channel masks, sampling-rate codes, hardware trigger thresholds, and time synchronization.
- Receive and reassemble event packets with sampling-rate, channel, and trigger metadata.
- Display up to 16 channels and save enabled-channel waveforms as CSV files with JSON metadata.
- Load saved events for offline localization without an FPGA connection.
- Perform voltage conversion, dynamic threshold detection, local D1-AIC arrival-time picking, and two-dimensional localization.
- Display arrival times, residuals, estimated coordinates, and localization errors when reference coordinates are available.

The FPGA performs synchronous acquisition and event capture; the host computer performs arrival-time picking and coordinate estimation. Exported waveforms have passed through the selected firmware processing chain and are not necessarily unfiltered ADC samples.

### Main Files

| Path | Purpose |
| --- | --- |
| `ae_acq_loc_gui_d1aic.py` | Main D1-AIC acquisition and localization GUI described here |
| `ae_localization/d1_aic_core.py` | D1-AIC, FFT diagnostics, velocity selection, and arrival-time residual localization |
| `ae_fpga_client/config.py` | Default network, sampling-rate, and event settings |
| `ae_fpga_client/protocol.py` | Control encoding, status/event decoding, and event reassembly |
| `ae_fpga_client/udp_client.py` | UDP communication and receive management |
| `ae_gui.py`, `ae_acq_loc_gui.py` | Earlier entry points using `ae_localization/core.py`, not the D1-AIC entry point above |
| `ae_localization/core.py` | Earlier localization pipeline and wave-propagation utilities |
| `ae_acq_loc_gui_adaptive_fullscreen.py`, `ae_acq_loc_gui_automatic_timed.py` | Alternative D1-AIC interfaces; verify their behavior and defaults before use |
| `batch_*.py` | Additional analysis scripts; their methods and settings may differ from the manuscript configuration |

### Environment and Launch

Use Python 3.9 or later with Tk support. The D1-AIC interface uses NumPy, SciPy, and Matplotlib. Earlier processing paths and some velocity calculations also use pandas; wavelet-packet functionality uses PyWavelets. The following is an installation example, not a guarantee of compatibility with every future package version.

Run from the application directory on Windows:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install numpy scipy matplotlib pandas PyWavelets
.\.venv\Scripts\python.exe -m tkinter
.\.venv\Scripts\python.exe ae_acq_loc_gui_d1aic.py
```

Tkinter is supplied by the Python/Tcl-Tk installation, not by `pip install tkinter`. Close the Tk test window before launching the application. Install SciPy to use the intended signal-processing and least-squares implementations.

This documentation was prepared by inspecting source code. A clean installation and hardware integration test were not repeated during documentation preparation. Include dependency versions from a working release environment, for example:

```powershell
python -m pip freeze > requirements-lock.txt
```

### Online Acquisition

1. Connect the matching hardware and assign the host Ethernet adapter a nonconflicting IPv4 address on the same subnet. Match GUI and firmware addresses and ports.
2. Launch the D1-AIC GUI, select the sampling rate, channel mask, and hardware trigger threshold, and send the configuration.
3. Enter sensor names and coordinates according to the physical wiring. Verify channel order and avoid unset or coincident sensor coordinates.
4. Acquire or request an event. Check its sequence number, packet count, sampling rate, channel mask, frame length, and trigger position. Resolve missing packets or decoding errors before analysis.
5. Save the event with its JSON metadata or localize the current event.

The hardware trigger threshold controls event capture. The D1-AIC dynamic threshold, expressed as a multiple of baseline RMS, controls software arrival-time detection. They operate at different stages and are not interchangeable. Set the hardware threshold according to the actual input and baseline conditions.

### Data Files and Units

Manual saving produces paired files: `Nchannel_x_y.csv` and `Nchannel_x_y.json`. N is the number of saved enabled channels; x and y are the entered reference source coordinates. The application generates a unique filename when necessary. Batch or timed interfaces may use different names; consult the metadata.

CSV files use UTF-8 with a byte-order mark. A typical header is:

```text
sample_index,time_us,CH01_S1,CH02_S2,CH03_S3,CH04_S4
```

| Field | Meaning |
| --- | --- |
| `sample_index` | Zero-based sample index |
| `time_us` | Time relative to the trigger, in microseconds, when valid timing is available |
| `CHxx_sensorname` | Signed channel codes stored in a 16-bit integer container, not voltage values |

Transporting 14-bit ADC codes in a 16-bit container does not increase ADC resolution. Under the experimental convention of a +/-1 V range with no additional code scaling, voltage is calculated as `V = code / 8192`. Recheck this relationship if firmware gain or calibration changes. This is an ADC-side equivalent voltage, not the sensor-input voltage corrected for analog front-end gain.

Normally, time is reconstructed from the sampling rate and trigger position. The save routine falls back to sample indices when a valid time axis is unavailable. The `time_us` column name alone therefore does not establish valid timing: verify the metadata.

| JSON field | Description and units |
| --- | --- |
| `sample_rate_hz` | Effective event sampling rate, Hz |
| `frame_samples`, `pre_samples`, `post_samples` | Frame length and pre-/post-trigger sample counts |
| `trigger_offset` | Zero-based trigger index within the frame |
| `channel_mask_hex`, `saved_channels` | Enabled-channel mask and saved channel order |
| `sensor_names` | Names of saved channels |
| `sensor_xy_m_saved_channels` | Sensor coordinates in saved channel order, m |
| `sensor_xy_m_all_ch1_to_ch16` | Coordinate configuration for all 16 channels, m |
| `target_xy_m` | Reference impact coordinates, m; used for error evaluation, not coordinate fitting |
| `event_seq`, `created_at` | Event sequence number and file creation time; file creation time is not physical event onset time |

Keep CSV and JSON files together. The JSON does not record every localization parameter, so comparative experiments also require a separate parameter record and code version.

### Offline Localization and Manuscript Settings

Load the CSV and matching JSON in the D1-AIC GUI, select the loaded dataset, and verify sampling rate, channel order, sensor coordinates, plate dimensions, and trigger position. Supply actual acquisition settings when metadata are missing rather than relying on fallback values.

The manuscript experiments used four channels at an effective rate of 1 MS/s, with 8192 samples per channel: 2048 pre-trigger and 6144 post-trigger samples.

| Channel | x (m) | y (m) |
| --- | --- | --- |
| CH01 | 0.1 | 0.4 |
| CH02 | 0.1 | 0.1 |
| CH03 | 0.4 | 0.1 |
| CH04 | 0.4 | 0.4 |

| Parameter | Setting |
| --- | --- |
| Search domain | Both x and y bounded to 0-0.5 m |
| Scaling and preprocessing | Divide codes by 8192; remove mean; software high-pass filter disabled |
| First difference | Absolute first difference without division by the sampling interval; difference smoothing set to 1 point |
| Threshold search | -200 to 400 microseconds relative to the hardware trigger |
| RMS baseline window | 60 microseconds before the threshold-search start: -260 to -200 microseconds |
| Dynamic threshold | 10 times each channel's difference-signal baseline RMS |
| AIC window | -80 to 100 microseconds relative to the channel's threshold crossing |
| AIC smoothing / min_side | 5 points / 10 points |
| FFT diagnostic window | 1 microsecond before to 80 microseconds after the picked arrival |
| FFT frequency range / zero-padding factor | 80-500 kHz / 4 |
| Propagation velocity | Manual fixed velocity enabled, 3150 m/s |
| Initialization | 11 x 11 grid; the inspected implementation also adds the sensor-array center, giving 122 starting-point calls |

In fixed-velocity mode, FFT analysis is diagnostic and does not update the 3150 m/s velocity. Automatic Lamb-wave velocity selection is a separate mode and should not be mixed with the fixed-velocity comparison.

The configuration file retains legacy fallback values of 4096/4096 pre-/post-trigger samples and a trigger offset of 4096. Use the actual event-header or JSON values for the 2048/6144 experimental configuration. The default sampling rate also differs from the 1 MS/s manuscript setting.

Outputs include coordinates in meters, arrival times and residuals in microseconds, and optional localization error. The core field `error_mm` uses millimeters, while some GUI error displays use meters. Localization error is the Euclidean distance between estimated and reference impact coordinates.

## FPGA Project

Use a compatible host-software protocol version and keep the firmware configuration associated with each recorded dataset.

### Directory Structure and Data Flow

```text
AE_project.xpr
AE_project.srcs/
  constrs_1/new/demo.xdc
  sources_1/new/
    top.v
    debug_cfg.vh
    ae_data_process/
    ae_event_capture/
    ae_ddr/
    eth/
    udp_rec_decode.v
    udp_event_sensor_tx.v
    event_time_keeper.v
  sources_1/ip/
  sim_1/new/
    tb_top_system.v
    tb_top_smoke.v
```

| Directory or file | Function |
| --- | --- |
| `ae_data_process/` | ADC interfacing, synchronization, 14-to-16-bit sign extension, and digital filtering |
| `ae_event_capture/ae_adc_data_downsampler.v` | Integer decimation based on valid input samples |
| `ae_event_capture/` | Trigger detection, pre-trigger recording, event organization, and stream output |
| `ae_ddr/` | Event headers, descriptors, and DDR read/write control |
| `eth/` | UDP communication and GMII/RGMII conversion |
| `udp_rec_decode.v` | Host control-parameter decoding |
| `udp_event_sensor_tx.v` | Event and status transmission |
| `event_time_keeper.v` | Time-information management |
| `debug_cfg.vh` | Debug macros affecting ILA dependencies and resource usage |

ADC data pass through digital preprocessing and decimation before event capture, DDR storage, and UDP transmission. When an enabled channel satisfies the trigger condition, enabled channels record the same event interval, preserving temporal correspondence for host-side analysis.

### IP and External Dependencies

The XPR references two inputs outside `AE_project_final` but included in this repository:

```text
../adc_data_preprocess/adc_data_preprocess.srcs/sources_1/ip/fir_500k_lp/fir_500k_lp.xci
../AE0512/AE_Multichannel/fir_lp500k_63tap_unsigned_integer.coe
```

The FIR XCI also references the COE file internally. Copying only `AE_project_final` is insufficient: retain the accompanying dependency directories. Preserve these dependencies and relative directories, or move them into a release copy and update both XPR and XCI references. Verify IP regeneration from the new location.

The project uses Vivado clocking, DDR3, FIFO, BRAM, and ILA IP. Retain referenced `.xci` files, required initialization/coefficient files, and user sources. RTL alone is insufficient to reconstruct configured IP blocks. Review IP settings before upgrading the tool version.

### Opening and Building

1. Install Vivado 2020.2 with support for the target Artix-7 device and prepare the matching hardware.
2. Open a working copy of `AE_project.xpr`. Confirm part `xc7a200tfbg484-2` and synthesis top `top`.
3. Inspect Sources and IP Status. Resolve external FIR IP and COE references before generating IP output products.
4. Verify `demo.xdc` pin assignments, I/O standards, external clocks, and board connections. Clocking and DDR IP constraints also contribute to the design constraints.
5. Check event-length and network parameters in `top.v` and debug settings in `debug_cfg.vh`. Keep settings consistent with the intended release.
6. Run synthesis and implementation. Review DRC and implemented timing reports before generating a bitstream. Bitstream generation alone does not establish timing closure.
7. Connect the hardware through Vivado Hardware Manager and load the bitstream. If using ILA, use its matching debug probes file.
8. Start the companion application, send acquisition settings, and verify event reception.

Synthesis, implementation, simulation, and board programming were not repeated during documentation preparation. No new timing-closure or test-pass claims are made here. Actual build logs and timing summaries can be associated with the release.

### Simulation Sources

The project contains `tb_top_system.v` and `tb_top_smoke.v`; the XPR selects `tb_top_system` as simulation top. These files provide starting points for examining interfaces and stimuli. Their presence does not establish complete functional coverage or a passing simulation for the released version.

Simulation models, substitute modules, and parameters may differ from the board implementation. Inspect `SIM_ADC_PREPROCESS_STUB` and other simulation switches before testing. Do not unintentionally synthesize a testbench-only configuration.

Source availability does not replace timing or functional verification reports. Tests that have not been executed are not represented as passing.

## Experimental Configuration and Validation Scope

The authors report acquisition verification with all 16 channels enabled at 40 MS/s per channel. This differs from the four-channel localization configuration and does not imply continuous lossless transmission of all raw channel data over Gigabit Ethernet. Transfer uses captured event records and packetization.

During hardware checks, verify clock locking, ADC reception, processed baseline levels, trigger settings, frame length, and host-side metadata and packet statistics. A common input can check channel correspondence. Voltage conversion must remain consistent with the 14-bit code scale.

The manuscript evaluates impacts on 2, 4, and 6 mm aluminum plates with a fixed four-node arrangement. Support for additional channels does not establish equivalent accuracy for every configuration. The fixed 3150 m/s value is an equivalent propagation parameter for these experiments; other materials, thicknesses, coupling conditions, and boundaries require reassessment.

The code directory does not automatically include the complete 300-event dataset or all event-level results. Published data should include dataset versions, plate thicknesses, reference coordinates, paired CSV/JSON files, and processing settings. Running the application alone does not reproduce all manuscript statistics.

## Release Contents and Related Work

Retain the XPR, referenced RTL and headers, XDC constraints, IP configurations, COE/initialization files, testbenches, and supporting documentation. Run directories, caches, generated products, and temporary logs are generally regenerable, but first verify they contain no unique required inputs. Rebuilding from a separate directory checks release completeness.

Include dependency versions from the working host environment, the Vivado version and IP configuration, and release identifiers for both components. If host software and FPGA sources are published in separate repositories, provide reciprocal links. For a combined repository, identify each component directory and associate experimental results with the same release or commit.

Associated manuscript: *MEMS acoustic emission source localization with compact FPGA-based event acquisition*.

Before publication, add the manuscript DOI when available, repository links, the release identifier, and the selected license. Preserve copyright notices for third-party IP and externally sourced code. This README is not a license and does not grant redistribution rights for third-party components.
