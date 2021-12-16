#!/usr/bin/env python3
'''
Test batsim CLI option group-simultaneous-events.
'''
from helper import *

def test():
    pf = 'platforms/energy_platform_homogeneous_no_net_1.xml'
    wl = 'workloads/test_group_simultaneous_events.json'
    algo = 'filler'
    test_name = 'group-simultaneous-events'

    output_dir, robin_filename, _ = init_instance(test_name)

    batcmd = gen_batsim_cmd(pf, wl, output_dir, "")
    instance = RobinInstance(output_dir=output_dir,
        batcmd=batcmd,
        schedcmd=f"batsched -v '{algo}'",
        simulation_timeout=30, ready_timeout=5,
        success_timeout=10, failure_timeout=0
    )

    instance.to_file(robin_filename)
    ret = run_robin(robin_filename)
    if ret.returncode != 0: raise Exception(f'Bad robin return code ({ret.returncode})')

