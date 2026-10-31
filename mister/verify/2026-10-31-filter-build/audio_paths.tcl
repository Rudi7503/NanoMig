# Audio/Capture-Pfade, Setup UND Hold, mit Anzahl gefundener Pfade.
# Laeuft auf der Datenbank des Builds mit RBF 2d42d81d.
project_open Minimig
create_timing_netlist
read_sdc
update_timing_netlist

foreach side {audio_ext audio_capture} {
    foreach mode {setup hold} {
        foreach dir {to from} {
            set f "${side}_${mode}_${dir}.rpt"
            if {$dir eq "to"} {
                report_timing -$mode -to   [get_registers *${side}*] -npaths 5 -detail summary -file $f
            } else {
                report_timing -$mode -from [get_registers *${side}*] -npaths 5 -detail summary -file $f
            }
        }
    }
}
delete_timing_netlist
project_close
