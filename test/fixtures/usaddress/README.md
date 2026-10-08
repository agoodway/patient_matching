# usaddress labeled addresses

Copied unchanged from
[datamade/usaddress](https://github.com/datamade/usaddress/tree/aa7699b53a0843fc443f9e87285b88cbd9eaf50a/measure_performance/test_data)
at commit `aa7699b53a0843fc443f9e87285b88cbd9eaf50a` (MIT, see `LICENSE`). Each `<AddressString>` is one
address whose tokens carry usaddress component labels (`AddressNumber`,
`StreetNamePostType`, `OccupancyType`, `USPSBoxType`, ...).
`test/patient_matching/usaddress_test.exs` uses the labels as ground truth for
street normalization.
