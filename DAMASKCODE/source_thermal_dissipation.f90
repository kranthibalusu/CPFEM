! Copyright 2011-16 Max-Planck-Institut für Eisenforschung GmbH
! 
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
! 
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
! 
! You should have received a copy of the GNU General Public License
! along with this program. If not, see <http://www.gnu.org/licenses/>.
!--------------------------------------------------------------------------------------------------
!> @author Pratheek Shanthraj, Max-Planck-Institut für Eisenforschung GmbH
!> @brief material subroutine for thermal source due to plastic dissipation
!> @details to be done
!--------------------------------------------------------------------------------------------------
module source_thermal_dissipation
 use prec, only: &
   pReal, &
   pInt

 implicit none
 private
 integer(pInt),                       dimension(:),           allocatable,         public, protected :: &
   source_thermal_dissipation_sizePostResults, &                                                        !< cumulative size of post results
   source_thermal_dissipation_offset, &                                                                 !< which source is my current thermal dissipation mechanism?
   source_thermal_dissipation_instance                                                                  !< instance of thermal dissipation source mechanism

 integer(pInt),                       dimension(:,:),         allocatable, target, public :: &
   source_thermal_dissipation_sizePostResult                                                            !< size of each post result output

 character(len=64),                   dimension(:,:),         allocatable, target, public :: &
   source_thermal_dissipation_output                                                                    !< name of each post result output
   
 integer(pInt),                       dimension(:),           allocatable, target, public :: &
   source_thermal_dissipation_Noutput                                                                   !< number of outputs per instance of this source 

 real(pReal),                         dimension(:),           allocatable,        private :: &
   source_thermal_dissipation_coldworkCoeff

 public :: &
   source_thermal_dissipation_init, &
   source_thermal_dissipation_getRateAndItsTangent

contains


!--------------------------------------------------------------------------------------------------
!> @brief module initialization
!> @details reads in material parameters, allocates arrays, and does sanity checks
!--------------------------------------------------------------------------------------------------
subroutine source_thermal_dissipation_init(fileUnit)
 use, intrinsic :: iso_fortran_env                                                                  ! to get compiler_version and compiler_options (at least for gfortran 4.6 at the moment)
 use debug, only: &
   debug_level,&
   debug_constitutive,&
   debug_levelBasic
 use IO, only: &
   IO_read, &
   IO_lc, &
   IO_getTag, &
   IO_isBlank, &
   IO_stringPos, &
   IO_stringValue, &
   IO_floatValue, &
   IO_intValue, &
   IO_warning, &
   IO_error, &
   IO_timeStamp, &
   IO_EOF
 use material, only: &
   phase_source, &
   phase_Nsources, &
   phase_Noutput, &
   SOURCE_thermal_dissipation_label, &
   SOURCE_thermal_dissipation_ID, &
   material_Nphase, &
   material_phase, &  
   sourceState, &
   MATERIAL_partPhase
 use numerics,only: &
   analyticJaco, &
   worldrank, &
   numerics_integrator

 implicit none
 integer(pInt), intent(in) :: fileUnit

 integer(pInt), allocatable, dimension(:) :: chunkPos
 integer(pInt) :: maxNinstance,phase,instance,source,sourceOffset
 integer(pInt) :: sizeState, sizeDotState, sizeDeltaState
 integer(pInt) :: NofMyPhase   
 character(len=65536) :: &
   tag  = '', &
   line = ''

 mainProcess: if (worldrank == 0) then 
   write(6,'(/,a)')   ' <<<+-  source_'//SOURCE_thermal_dissipation_label//' init  -+>>>'
   write(6,'(a15,a)') ' Current time: ',IO_timeStamp()
#include "compilation_info.f90"
 endif mainProcess
 
 maxNinstance = int(count(phase_source == SOURCE_thermal_dissipation_ID),pInt)
 if (maxNinstance == 0_pInt) return
 if (iand(debug_level(debug_constitutive),debug_levelBasic) /= 0_pInt) &
   write(6,'(a16,1x,i5,/)') '# instances:',maxNinstance
 
 allocate(source_thermal_dissipation_offset(material_Nphase), source=0_pInt)
 allocate(source_thermal_dissipation_instance(material_Nphase), source=0_pInt)
 do phase = 1, material_Nphase
   source_thermal_dissipation_instance(phase) = count(phase_source(:,1:phase) == SOURCE_thermal_dissipation_ID)
   do source = 1, phase_Nsources(phase)
     if (phase_source(source,phase) == SOURCE_thermal_dissipation_ID) &
       source_thermal_dissipation_offset(phase) = source
   enddo    
 enddo
   
 allocate(source_thermal_dissipation_sizePostResults(maxNinstance),                     source=0_pInt)
 allocate(source_thermal_dissipation_sizePostResult(maxval(phase_Noutput),maxNinstance),source=0_pInt)
 allocate(source_thermal_dissipation_output  (maxval(phase_Noutput),maxNinstance))
          source_thermal_dissipation_output = ''
 allocate(source_thermal_dissipation_Noutput(maxNinstance),                             source=0_pInt) 
 allocate(source_thermal_dissipation_coldworkCoeff(maxNinstance),                       source=0.0_pReal) 

 rewind(fileUnit)
 phase = 0_pInt
 do while (trim(line) /= IO_EOF .and. IO_lc(IO_getTag(line,'<','>')) /= MATERIAL_partPhase)         ! wind forward to <phase>
   line = IO_read(fileUnit)
 enddo
 
 parsingFile: do while (trim(line) /= IO_EOF)                                                       ! read through sections of phase part
   line = IO_read(fileUnit)
   if (IO_isBlank(line)) cycle                                                                      ! skip empty lines
   if (IO_getTag(line,'<','>') /= '') then                                                          ! stop at next part
     line = IO_read(fileUnit, .true.)                                                               ! reset IO_read
     exit                                                                                           
   endif   
   if (IO_getTag(line,'[',']') /= '') then                                                          ! next phase section
     phase = phase + 1_pInt                                                                         ! advance phase section counter
     cycle                                                                                          ! skip to next line
   endif

   if (phase > 0_pInt ) then; if (any(phase_source(:,phase) == SOURCE_thermal_dissipation_ID)) then ! do not short-circuit here (.and. with next if statemen). It's not safe in Fortran

     instance = source_thermal_dissipation_instance(phase)                                          ! which instance of my source is present phase
     chunkPos = IO_stringPos(line)
     tag = IO_lc(IO_stringValue(line,chunkPos,1_pInt))                                             ! extract key
     select case(tag)
       case ('dissipation_coldworkcoeff')
         source_thermal_dissipation_coldworkCoeff(instance) = IO_floatValue(line,chunkPos,2_pInt)

     end select
   endif; endif
 enddo parsingFile
 
 initializeInstances: do phase = 1_pInt, material_Nphase
   if (any(phase_source(:,phase) == SOURCE_thermal_dissipation_ID)) then
     NofMyPhase=count(material_phase==phase)
     instance = source_thermal_dissipation_instance(phase)
     sourceOffset = source_thermal_dissipation_offset(phase)

     sizeDotState              =   0_pInt
     sizeDeltaState            =   0_pInt
     sizeState                 =   0_pInt
     sourceState(phase)%p(sourceOffset)%sizeState =       sizeState
     sourceState(phase)%p(sourceOffset)%sizeDotState =    sizeDotState
     sourceState(phase)%p(sourceOffset)%sizeDeltaState =  sizeDeltaState
     sourceState(phase)%p(sourceOffset)%sizePostResults = source_thermal_dissipation_sizePostResults(instance)
     allocate(sourceState(phase)%p(sourceOffset)%aTolState           (sizeState),                source=0.0_pReal)
     allocate(sourceState(phase)%p(sourceOffset)%state0              (sizeState,NofMyPhase),     source=0.0_pReal)
     allocate(sourceState(phase)%p(sourceOffset)%partionedState0     (sizeState,NofMyPhase),     source=0.0_pReal)
     allocate(sourceState(phase)%p(sourceOffset)%subState0           (sizeState,NofMyPhase),     source=0.0_pReal)
     allocate(sourceState(phase)%p(sourceOffset)%state               (sizeState,NofMyPhase),     source=0.0_pReal)

     allocate(sourceState(phase)%p(sourceOffset)%dotState            (sizeDotState,NofMyPhase),  source=0.0_pReal)
     allocate(sourceState(phase)%p(sourceOffset)%deltaState        (sizeDeltaState,NofMyPhase),  source=0.0_pReal)
     if (.not. analyticJaco) then
       allocate(sourceState(phase)%p(sourceOffset)%state_backup      (sizeState,NofMyPhase),     source=0.0_pReal)
       allocate(sourceState(phase)%p(sourceOffset)%dotState_backup   (sizeDotState,NofMyPhase),  source=0.0_pReal)
     endif
     if (any(numerics_integrator == 1_pInt)) then
       allocate(sourceState(phase)%p(sourceOffset)%previousDotState  (sizeDotState,NofMyPhase),  source=0.0_pReal)
       allocate(sourceState(phase)%p(sourceOffset)%previousDotState2 (sizeDotState,NofMyPhase),  source=0.0_pReal)
     endif
     if (any(numerics_integrator == 4_pInt)) &
       allocate(sourceState(phase)%p(sourceOffset)%RK4dotState       (sizeDotState,NofMyPhase),  source=0.0_pReal)
     if (any(numerics_integrator == 5_pInt)) &
       allocate(sourceState(phase)%p(sourceOffset)%RKCK45dotState    (6,sizeDotState,NofMyPhase),source=0.0_pReal)      

   endif
 
 enddo initializeInstances
end subroutine source_thermal_dissipation_init

!--------------------------------------------------------------------------------------------------
!> @brief returns local vacancy generation rate 
!--------------------------------------------------------------------------------------------------
subroutine source_thermal_dissipation_getRateAndItsTangent(TDot, dTDOT_dT, Tstar_v, Lp, ipc, ip, el)
 use math, only: &
   math_Mandel6to33
 use material, only: &
   phaseAt, phasememberAt

 implicit none
 integer(pInt), intent(in) :: &
   ipc, &                                                                                           !< grain number
   ip, &                                                                                            !< integration point number
   el                                                                                               !< element number
 real(pReal),  intent(in), dimension(6) :: &
   Tstar_v                                                                                          !< 2nd Piola Kirchhoff stress tensor (Mandel)
 real(pReal),  intent(in), dimension(3,3) :: &
   Lp
 real(pReal),  intent(out) :: &
   TDot, &
   dTDOT_dT
 integer(pInt) :: &
   instance, phase, constituent 

 phase = phaseAt(ipc,ip,el)
 constituent = phasememberAt(ipc,ip,el)
 instance = source_thermal_dissipation_instance(phase)
 
 TDot = source_thermal_dissipation_coldworkCoeff(instance)* &
        sum(abs(math_Mandel6to33(Tstar_v)*Lp))
 dTDOT_dT = 0.0_pReal       
 
end subroutine source_thermal_dissipation_getRateAndItsTangent
 
end module source_thermal_dissipation
