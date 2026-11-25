package main

/*
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
static int sample(int pid,double *cpu,int64_t *rss,int64_t *wakes) {
 struct rusage_info_v2 info;
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t*)&info)!=0)return -1;
 mach_timebase_info_data_t scale;
 if(mach_timebase_info(&scale)!=KERN_SUCCESS || !scale.denom)return -1;
 *cpu=(double)(info.ri_user_time+info.ri_system_time)*scale.numer/scale.denom/1e9;
 *rss=info.ri_resident_size;
 *wakes=info.ri_interrupt_wkups;
 return 0;
}
*/
import "C"
import "fmt"

func sampleUsage(pid int) (usage, error) {
	var cpu C.double
	var rss, wakes C.int64_t
	if C.sample(C.int(pid), &cpu, &rss, &wakes) != 0 {
		return usage{}, fmt.Errorf("proc_pid_rusage failed for %d", pid)
	}
	w := int64(wakes)
	return usage{float64(cpu), int64(rss), &w, "rusage_info_v2.ri_interrupt_wkups"}, nil
}
