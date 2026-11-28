set src_dir [file dirname [file normalize [info script]]]
open_project [file join $src_dir nanomig_tc138k.gprj]
run syn
run pnr
exit
