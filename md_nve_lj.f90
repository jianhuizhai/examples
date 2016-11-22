! md_nve_lj.f90
! Molecular dynamics, NVE ensemble
PROGRAM md_nve_lj

  USE, INTRINSIC :: iso_fortran_env, ONLY : input_unit, output_unit, error_unit, iostat_end, iostat_eor

  USE config_io_module, ONLY : read_cnf_atoms, write_cnf_atoms
  USE averages_module,  ONLY : time_stamp, run_begin, run_end, blk_begin, blk_end, blk_add, variable_type
  USE md_module,        ONLY : introduction, conclusion, allocate_arrays, deallocate_arrays, &
       &                       force, r, v, f, n, potential_type

  IMPLICIT NONE

  ! Takes in a configuration of atoms (positions, velocities)
  ! Cubic periodic boundary conditions
  ! Conducts molecular dynamics using velocity Verlet algorithm
  ! Uses no special neighbour lists

  ! Reads several variables and options from standard input using a namelist nml
  ! Leave namelist empty to accept supplied defaults

  ! Positions r are divided by box length after reading in and we assume mass=1 throughout
  ! However, input configuration, output configuration, most calculations, and all results 
  ! are given in simulation units defined by the model
  ! For example, for Lennard-Jones, sigma = 1, epsilon = 1

  ! Despite the program name, there is nothing here specific to Lennard-Jones
  ! The model is defined in md_module

  ! Most important variables
  REAL :: box     ! Box length
  REAL :: dt      ! Time step
  REAL :: r_cut   ! Potential cutoff distance

  ! Quantities to be averaged
  TYPE(variable_type), DIMENSION(:), ALLOCATABLE :: variables

  ! Composite interaction = pot & cut & vir & lap & ovr variables
  TYPE(potential_type) :: total

  INTEGER            :: blk, stp, nstep, nblock, ioerr
  REAL, DIMENSION(3) :: vcm

  CHARACTER(len=4), PARAMETER :: cnf_prefix = 'cnf.'
  CHARACTER(len=3), PARAMETER :: inp_tag    = 'inp'
  CHARACTER(len=3), PARAMETER :: out_tag    = 'out'
  CHARACTER(len=3)            :: sav_tag    = 'sav' ! May be overwritten with block number

  NAMELIST /nml/ nblock, nstep, r_cut, dt

  WRITE ( unit=output_unit, fmt='(a)' ) 'md_nve_lj'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Molecular dynamics, constant-NVE ensemble'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Particle mass=1 throughout'
  CALL introduction ( output_unit )
  CALL time_stamp ( output_unit )

  ! Set sensible default run parameters for testing
  nblock = 10
  nstep  = 50000
  r_cut  = 2.5
  dt     = 0.002

  ! Read run parameters from namelist
  ! Comment out, or replace, this section if you don't like namelists
  READ ( unit=input_unit, nml=nml, iostat=ioerr )
  IF ( ioerr /= 0 ) THEN
     WRITE ( unit=error_unit, fmt='(a,i15)') 'Error reading namelist nml from standard input', ioerr
     IF ( ioerr == iostat_eor ) WRITE ( unit=error_unit, fmt='(a)') 'End of record'
     IF ( ioerr == iostat_end ) WRITE ( unit=error_unit, fmt='(a)') 'End of file'
     STOP 'Error in md_nve_lj'
  END IF

  ! Write out run parameters
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of blocks',          nblock
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of steps per block', nstep
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Potential cutoff distance', r_cut
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Time step',                 dt

  ! Read in initial configuration and allocate necessary arrays
  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box ) ! First call is just to get n and box
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of particles',   n
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Simulation box length', box
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Density',               REAL(n) / box**3
  CALL allocate_arrays ( box, r_cut )
  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, box, r, v ) ! Second call gets r and v
  r(:,:) = r(:,:) / box                                     ! Convert positions to box units
  r(:,:) = r(:,:) - ANINT ( r(:,:) )                        ! Periodic boundaries
  vcm(:) = SUM ( v(:,:), dim=2 ) / REAL(n)                  ! Centre-of mass velocity
  v(:,:) = v(:,:) - SPREAD ( vcm(:), dim = 2, ncopies = n ) ! Set COM velocity to zero

  ! Initial forces, potential, etc plus overlap check
  CALL force ( box, r_cut, total )
  IF ( total%ovr ) THEN
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in initial configuration'
     STOP 'Error in md_nve_lj'
  END IF
  CALL calculate ( 'Initial values' )

  ! Initialize arrays for averaging and write column headings
  CALL run_begin ( output_unit, variables )

  DO blk = 1, nblock ! Begin loop over blocks

     CALL blk_begin

     DO stp = 1, nstep ! Begin loop over steps

        ! Velocity Verlet algorithm
        v(:,:) = v(:,:) + 0.5 * dt * f(:,:) ! Kick half-step

        r(:,:) = r(:,:) + dt * v(:,:) / box ! Drift step (positions in box=1 units)
        r(:,:) = r(:,:) - ANINT ( r(:,:) )  ! Periodic boundaries

        CALL force ( box, r_cut, total ) ! Force evaluation
        IF ( total%ovr ) THEN
           WRITE ( unit=error_unit, fmt='(a)') 'Overlap in configuration'
           STOP 'Error in md_nve_lj'
        END IF

        v(:,:) = v(:,:) + 0.5 * dt * f(:,:) ! Kick half-step

        ! Calculate and accumulate variables for this step
        CALL calculate ( )
        CALL blk_add ( variables )

     END DO ! End loop over steps

     CALL blk_end ( blk, output_unit )                              ! Output block averages
     IF ( nblock < 1000 ) WRITE(sav_tag,'(i3.3)') blk               ! Number configuration by block
     CALL write_cnf_atoms ( cnf_prefix//sav_tag, n, box, r*box, v ) ! Save configuration

  END DO ! End loop over blocks

  CALL run_end ( output_unit ) ! Output run averages

  CALL force ( box, r_cut, total )
  IF ( total%ovr ) THEN ! should never happen
     WRITE ( unit=error_unit, fmt='(a)') 'Overlap in final configuration'
     STOP 'Error in md_nve_lj'
  END IF
  CALL calculate ( 'Final values' )
  CALL time_stamp ( output_unit )

  CALL write_cnf_atoms ( cnf_prefix//out_tag, n, box, r*box, v ) ! Write out final configuration

  CALL deallocate_arrays
  CALL conclusion ( output_unit )

CONTAINS

  SUBROUTINE calculate ( string ) 
    USE md_module,       ONLY : potential_lrc, pressure_lrc, hessian
    USE averages_module, ONLY : write_variables
    IMPLICIT NONE
    CHARACTER (len=*), INTENT(in), OPTIONAL :: string

    ! This routine calculates all variables of interest and (optionally) writes them out
    ! They are collected together in the variables array, for use in the main program

    TYPE(variable_type) :: e_s, p_s, e_f, p_f, t_k, t_c, pe_msd, conserved_msd
    REAL                :: vol, rho, fsq, kin, hes, tmp

    ! Preliminary calculations
    vol = box**3                  ! Volume
    rho = REAL(n) / vol           ! Density
    kin = 0.5*SUM(v**2)           ! Kinetic energy
    tmp = 2.0 * kin / REAL(3*n-3) ! Remove three degrees of freedom for momentum conservation
    fsq = SUM ( f**2 )            ! Total squared force
    hes = hessian(box,r_cut)      ! Total Hessian

    ! Variables of interest, of type variable_type, containing three components:
    !   %val: the instantaneous value
    !   %nam: used for headings
    !   %msd: indicating if mean squared deviation required
    ! If not set below, %msd adopts its default value of .false.
    ! The %msd and %nam components need only be defined once, at the start of the program,
    ! but for clarity and readability we assign all the values together below

    ! Internal energy (cut-and-shifted) per atom
    ! Total KE plus total cut-and-shifted PE divided by N
    e_s = variable_type ( nam = 'E/N:cut&shifted', val = (kin+total%pot)/REAL(n) )

    ! Internal energy (full, including LRC) per atom
    ! LRC plus total KE plus total cut (but not shifted) PE divided by N
    e_f = variable_type ( nam = 'E/N:full', val = potential_lrc(rho,r_cut) + (kin+total%cut)/REAL(n) )

    ! Pressure (cut-and-shifted)
    ! Ideal gas contribution plus total virial divided by V
    p_s = variable_type ( nam = 'P:cut&shifted', val = rho*tmp + total%vir/vol )

    ! Pressure (full, including LRC)
    ! LRC plus ideal gas contribution plus total virial divided by V
    p_f = variable_type ( nam = 'P:full', val = pressure_lrc(rho,r_cut) + rho*tmp + total%vir/vol )

    ! Kinetic temperature
    t_k = variable_type ( nam = 'T:kinetic', val = tmp )

    ! Configurational temperature
    ! Total squared force divided by total Laplacian with small Hessian correction
    t_c = variable_type ( nam = 'T:config', val = fsq/(total%lap-(2.0*hes/fsq)) )

    ! Mean-squared deviation of cut-and-shifted potential energy, intensive
    ! This may be used to calculate the heat capacity Cv
    pe_msd = variable_type ( nam = 'PE/sqrt(N):MSD', val = total%pot/SQRT(REAL(n)), msd = .TRUE. )

    ! Mean-squared deviation of conserved energy
    conserved_msd = variable_type ( nam = 'E:MSD', val = kin+total%pot, msd = .TRUE. )

    ! Collect together for averaging
    ! Fortran 2003 should automatically allocate this first time
    variables = [ e_s, p_s, e_f, p_f, t_k, t_c, pe_msd, conserved_msd ]

    IF ( PRESENT ( string ) ) THEN
       WRITE ( unit=output_unit, fmt='(a)' ) string
       CALL write_variables ( output_unit, variables(1:6) ) ! Don't write out MSD variables
    END IF

  END SUBROUTINE calculate

END PROGRAM md_nve_lj

