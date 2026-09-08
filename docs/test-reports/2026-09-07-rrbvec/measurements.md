# Owner measurements

Each row reports the median of six native samples after discarding the first sample. Time is microseconds per operation; brackets show the observed minimum and maximum. Allocation is bytes per operation on arm64. Ratios are vector / List.

## overlay-128 (combined)

Raw samples: [overlay-128-list.log](overlay-128-list.log), [overlay-128-vector.log](overlay-128-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 46632.522 [45841.375, 47396.542] | 46766.104 [46163.708, 47787.750] | 1.003 | 139668920 | 139785924 | 1.001 |
| block-read | 95.907 [93.828, 99.526] | 96.768 [95.454, 98.524] | 1.009 | 287792 | 287792 | 1.000 |
| page-read | 31.814 [31.178, 33.293] | 32.306 [31.098, 32.710] | 1.015 | 75074 | 75074 | 1.000 |
| structure-read | 577.992 [562.731, 605.087] | 576.850 [576.127, 587.835] | 0.998 | 1392765 | 1392765 | 1.000 |

## overlay-128-shared (combined)

Raw samples: [overlay-128-shared-list.log](overlay-128-shared-list.log), [overlay-128-shared-vector.log](overlay-128-shared-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 29711.229 [29132.333, 29819.667] | 29646.980 [29072.542, 30230.292] | 0.998 | 101102528 | 100945152 | 0.998 |
| block-read | 113.449 [110.451, 114.787] | 113.082 [110.563, 114.537] | 0.997 | 458482 | 458482 | 1.000 |
| page-read | 32.691 [30.468, 33.204] | 32.285 [31.716, 32.973] | 0.988 | 75074 | 75074 | 1.000 |
| structure-read | 549.376 [542.894, 558.669] | 549.915 [542.385, 553.227] | 1.001 | 1406189 | 1406189 | 1.000 |

## overlay-32 (combined)

Raw samples: [overlay-32-list.log](overlay-32-list.log), [overlay-32-vector.log](overlay-32-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 11810.583 [11533.000, 11829.083] | 11698.209 [11612.584, 13305.959] | 0.990 | 34943692 | 34973288 | 1.001 |
| block-read | 95.817 [93.895, 98.292] | 96.107 [94.133, 104.410] | 1.003 | 287792 | 287792 | 1.000 |
| page-read | 32.536 [31.265, 32.930] | 31.705 [31.072, 35.142] | 0.974 | 75074 | 75074 | 1.000 |
| structure-read | 547.139 [542.875, 550.362] | 547.370 [546.110, 586.008] | 1.000 | 1284605 | 1284605 | 1.000 |

## overlay-32-shared (combined)

Raw samples: [overlay-32-shared-list.log](overlay-32-shared-list.log), [overlay-32-shared-vector.log](overlay-32-shared-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 7327.166 [7265.125, 7496.542] | 7385.729 [7302.542, 7711.458] | 1.008 | 21580560 | 21578160 | 1.000 |
| block-read | 98.156 [96.828, 99.545] | 99.761 [96.082, 103.343] | 1.016 | 329460 | 329460 | 1.000 |
| page-read | 31.720 [31.094, 32.304] | 31.771 [30.788, 32.955] | 1.002 | 75074 | 75074 | 1.000 |
| structure-read | 528.482 [522.590, 532.663] | 535.768 [527.931, 566.675] | 1.014 | 1277165 | 1277165 | 1.000 |

## overlay-4096 (combined)

Raw samples: [overlay-4096-list.log](overlay-4096-list.log), [overlay-4096-vector.log](overlay-4096-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 1789043.833 [1774771.667, 1807435.791] | 1784741.479 [1780159.167, 1790536.792] | 0.998 | 5861858416 | 5865659600 | 1.001 |
| block-read | 112.818 [111.686, 119.111] | 112.067 [110.165, 113.174] | 0.993 | 364427 | 364427 | 1.000 |
| page-read | 36.195 [35.766, 36.713] | 35.475 [34.983, 36.256] | 0.980 | 95354 | 95354 | 1.000 |
| structure-read | 813.627 [796.271, 825.931] | 794.824 [791.900, 801.217] | 0.977 | 1811685 | 1811685 | 1.000 |

## overlay-4096-shared (combined)

Raw samples: [overlay-4096-shared-list.log](overlay-4096-shared-list.log), [overlay-4096-shared-vector.log](overlay-4096-shared-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| replan | 3135764.167 [3120091.625, 3168425.083] | 3075522.104 [3060245.667, 3082216.541] | 0.981 | 26103733856 | 25903671736 | 0.992 |
| block-read | 581.429 [574.985, 591.312] | 590.336 [586.274, 596.213] | 1.015 | 5868122 | 5868122 | 1.000 |
| page-read | 35.926 [34.954, 36.367] | 35.965 [34.488, 36.868] | 1.001 | 95354 | 95354 | 1.000 |
| structure-read | 1214.029 [1196.231, 1233.310] | 1223.480 [1199.829, 1251.096] | 1.008 | 7156061 | 7156061 | 1.000 |

## timeline-16 (combined)

Raw samples: [timeline-16-list.log](timeline-16-list.log), [timeline-16-vector.log](timeline-16-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| window-0 | 0.083 [0.082, 0.083] | 0.097 [0.094, 0.098] | 1.173 | 824 | 456 | 0.553 |
| prepare-0 | 2.976 [2.883, 2.987] | 3.083 [2.959, 3.108] | 1.036 | 17217 | 16488 | 0.958 |
| window-8 | 0.076 [0.075, 0.078] | 0.114 [0.112, 0.114] | 1.489 | 632 | 528 | 0.835 |
| prepare-8 | 2.989 [2.937, 3.060] | 3.089 [3.033, 3.119] | 1.033 | 17025 | 16560 | 0.973 |
| update | 0.098 [0.098, 0.100] | 0.108 [0.101, 0.119] | 1.099 | 592 | 488 | 0.824 |
| splice | 0.204 [0.187, 0.227] | 0.301 [0.295, 0.305] | 1.479 | 2160 | 1672 | 0.774 |

## timeline-512 (combined)

Raw samples: [timeline-512-list.log](timeline-512-list.log), [timeline-512-vector.log](timeline-512-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| window-0 | 0.142 [0.139, 0.145] | 0.201 [0.198, 0.211] | 1.414 | 1976 | 1344 | 0.680 |
| prepare-0 | 95.390 [94.590, 97.234] | 93.263 [92.825, 96.456] | 0.978 | 522302 | 509409 | 0.975 |
| window-256 | 0.308 [0.254, 0.312] | 0.204 [0.200, 0.209] | 0.664 | 1976 | 1352 | 0.684 |
| prepare-256 | 94.420 [94.262, 97.708] | 94.662 [92.281, 95.352] | 1.003 | 522302 | 509417 | 0.975 |
| window-472 | 0.421 [0.354, 0.464] | 0.203 [0.192, 0.214] | 0.482 | 1976 | 1496 | 0.757 |
| prepare-472 | 96.408 [93.868, 97.772] | 94.601 [92.160, 95.756] | 0.981 | 522302 | 509561 | 0.976 |
| update | 2.762 [2.717, 2.781] | 2.526 [2.468, 2.565] | 0.915 | 12496 | 616 | 0.049 |
| splice | 5.695 [5.651, 5.770] | 6.317 [6.244, 6.576] | 1.109 | 49912 | 4784 | 0.096 |

## worker-16 (combined)

Raw samples: [worker-16-list.log](worker-16-list.log), [worker-16-vector.log](worker-16-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| publish | 898.715 [886.818, 913.057] | 885.893 [880.383, 896.763] | 0.986 | 1683486 | 1683878 | 1.000 |
| pull-front | 33.755 [31.810, 35.346] | 30.599 [29.117, 35.070] | 0.907 | 5160 | 4800 | 0.930 |
| pull-middle | 34.505 [32.448, 35.556] | 31.395 [28.982, 35.184] | 0.910 | 5192 | 4992 | 0.961 |
| ack | 37.666 [22.541, 45.625] | 39.688 [34.084, 47.666] | 1.054 | 4344 | 4328 | 0.996 |
| interleaved | 905.523 [883.571, 929.975] | 910.421 [895.067, 931.867] | 1.005 | 1859202 | 1859742 | 1.000 |

## worker-16 (worker-only)

Raw samples: [worker-16-list.log](worker-16-list.log), [worker-16-isolated-vector.log](worker-16-isolated-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| publish | 898.715 [886.818, 913.057] | 886.880 [867.620, 895.208] | 0.987 | 1683486 | 1683433 | 1.000 |
| pull-front | 33.755 [31.810, 35.346] | 35.636 [33.208, 37.371] | 1.056 | 5160 | 4800 | 0.930 |
| pull-middle | 34.505 [32.448, 35.556] | 35.486 [33.020, 37.001] | 1.028 | 5192 | 4992 | 0.961 |
| ack | 37.666 [22.541, 45.625] | 47.625 [46.625, 52.500] | 1.264 | 4344 | 4328 | 0.996 |
| interleaved | 905.523 [883.571, 929.975] | 903.381 [886.758, 908.913] | 0.998 | 1859202 | 1859186 | 1.000 |

## worker-512 (combined)

Raw samples: [worker-512-list.log](worker-512-list.log), [worker-512-vector.log](worker-512-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| publish | 2647.628 [2637.790, 2655.525] | 2638.321 [2629.907, 2641.080] | 0.996 | 7166442 | 7163552 | 1.000 |
| pull-front | 32.220 [31.285, 33.039] | 32.716 [32.278, 33.415] | 1.015 | 5160 | 4928 | 0.955 |
| pull-middle | 33.222 [32.239, 35.987] | 35.613 [33.731, 36.718] | 1.072 | 5208 | 5136 | 0.986 |
| ack | 40.063 [33.916, 51.750] | 45.938 [23.958, 58.792] | 1.147 | 4344 | 4328 | 0.996 |
| interleaved | 4329.300 [4309.500, 4424.450] | 4333.256 [4306.413, 4505.863] | 1.001 | 13057098 | 13062798 | 1.000 |

## worker-512 (worker-only)

Raw samples: [worker-512-list.log](worker-512-list.log), [worker-512-isolated-vector.log](worker-512-isolated-vector.log).

| Operation | List time, us [min, max] | Vector time, us [min, max] | Time ratio | List bytes | Vector bytes | Allocation ratio |
| --- | --- | --- | --- | --- | --- | --- |
| publish | 2647.628 [2637.790, 2655.525] | 2642.925 [2621.165, 2653.936] | 0.998 | 7166442 | 7160494 | 0.999 |
| pull-front | 32.220 [31.285, 33.039] | 32.587 [30.930, 34.677] | 1.011 | 5160 | 4928 | 0.955 |
| pull-middle | 33.222 [32.239, 35.987] | 33.530 [31.321, 36.348] | 1.009 | 5208 | 5136 | 0.986 |
| ack | 40.063 [33.916, 51.750] | 39.062 [21.458, 58.791] | 0.975 | 4344 | 4328 | 0.996 |
| interleaved | 4329.300 [4309.500, 4424.450] | 4361.542 [4304.479, 4428.408] | 1.007 | 13057098 | 13057082 | 1.000 |
