# δ is the maximal distance a particle is perturbed in a given coordinate
#  during particle translations
const δ = 0.35 # Å
const KB = 1.38064852e7 # Boltmann constant (Pa-m3/K --> Pa-A3/K)

# define Markov chain proposals here.
const PROPOSAL_ENCODINGS = Dict(1 => "insertion", 2 => "deletion", 3 => "translation")
const N_PROPOSAL_TYPES = length(keys(PROPOSAL_ENCODINGS))
const INSERTION = Dict([value => key for (key, value) in PROPOSAL_ENCODINGS])["insertion"]
const DELETION = Dict([value => key for (key, value) in PROPOSAL_ENCODINGS])["deletion"]
const TRANSLATION = Dict([value => key for (key, value) in PROPOSAL_ENCODINGS])["translation"]

"""
Data structure to keep track of statistics collected during a grand-canonical Monte Carlo
simulation.

* `n` is the number of molecules in the simulation box.
* `U` is the potential energy.
* `g` refers to guest (the adsorbate molecule).
* `h` refers to host (the crystalline framework).
"""
type GCMCstats
    n_samples::Int

    n::Int
    n²::Int

    U_gh::Float64
    U_gh²::Float64

    U_gg::Float64
    U_gg²::Float64

    U_ggU_gh::Float64
    Un::Float64 # ⟨U n⟩
end

"""
Keep track of Markov chain transitions (proposals and acceptances) during a grand-canonical
Monte Carlo simulation. Entry `i` of these arrays corresponds to PROPOSAL_ENCODINGS[i].
"""
type MarkovCounts
    n_proposed::Array{Int, 1}
    n_accepted::Array{Int, 1}
end

"""
    insert_molecule!(molecules::Array{Molecule, 1}, simulation_box::Box, template::Molecule)

Inserts an additional adsorbate molecule into the simulation box using the template provided.
The center of mass of the molecule is chosen at a uniform random position in the simulation box.
A uniformly random orientation of the molecule is chosen by rotating about the center of mass.
"""
function insert_molecule!(molecules::Array{Molecule, 1}, box::Box, template::Molecule)
    # choose center of mass
    x = box.f_to_c * rand(3)
    # copy the template
    molecule = deepcopy(template)
    # conduct a rotation
    if (length(molecule.ljspheres) + length(molecule.charges) > 1)
        rotate!(molecule)
    end
    # translate molecule to its new center of mass
    translate_to!(molecule, x)
    # push molecule to array.
    push!(molecules, molecule)
end

"""
    delete_molecule!(molecule_id::Int, molecules::Array{Molecule, 1})

Removes a random molecule from the current molecules in the framework.
molecule_id decides which molecule will be deleted, for a simulation, it must
    be a randomly generated value
"""
function delete_molecule!(molecule_id::Int, molecules::Array{Molecule, 1})
    splice!(molecules, molecule_id)
end

"""
    apply_periodic_boundary_condition!(molecule::Molecule, simulation_box::Box)

Check if the `center_of_mass` of a `Molecule` is outside of a `Box`. If so, apply periodic 
boundary conditions and translate the center of mass of the `Molecule` (and its atoms 
and point charges) so that it is inside of the `Box`.
"""
function apply_periodic_boundary_condition!(molecule::Molecule, box::Box)
    outside_box = false # do nothing if not outside the box

    # compute its center of mass in fractional coordinates
    xf = box.c_to_f * molecule.center_of_mass

    # apply periodic boundary conditions
    for k = 1:3 # loop over xf, yf, zf components
        # if > 1.0, shift down
        if xf[k] >= 1.0
            outside_box = true
            xf[k] -= 1.0
        elseif xf[k] < 0.0
            outside_box = true
            xf[k] += 1.0
        end
    end

    # translate molecule to new center of mass if it was found to be outside of the box
    if outside_box
        new_center_of_mass = box.f_to_c * xf
        translate_to!(molecule, new_center_of_mass)
    end
end

"""
    translate_molecule!(molecule::Molecule, simulation_box::Box)

Perturbs the Cartesian coordinates of a molecule about its center of mass by a random 
vector of max length δ. Applies periodic boundary conditions to keep the molecule inside 
the simulation box. Returns a deep copy of the old molecule in case it needs replaced
if the Monte Carlo proposal is rejected.
"""
function translate_molecule!(molecule::Molecule, simulation_box::Box)
    # store old molecule and return at the end for possible restoration
    old_molecule = deepcopy(molecule)
    # peturb in Cartesian coords in a random cube centered at current coords.
    dx = δ * (rand(3) - 0.5) # move every atom of the molecule by the same vector.
    translate_by!(molecule, dx)
    # done, unless the molecule has moved outside of the box, then apply PBC
    apply_periodic_boundary_condition!(molecule, simulation_box)

    return old_molecule # in case we need to restore
end

"""
    gg_energy = guest_guest_vdw_energy(molecule_id, molecules, ljforcefield, simulation_box)

Calculates van der Waals interaction energy of a single adsorbate `molecules[molecule_id]`
with all of the other molecules in the system. Periodic boundary conditions are applied,
using the nearest image convention.
"""
function guest_guest_vdw_energy(molecule_id::Int, molecules::Array{Molecule, 1},
                                ljforcefield::LennardJonesForceField, simulation_box::Box)
    energy = 0.0 # energy is pair-wise additive
    # Look at interaction with all other molecules in the system
    for this_ljsphere in molecules[molecule_id].ljspheres
        # Loop over all atoms in the given molecule
        for other_molecule_id = 1:length(molecules)
            # molecule cannot interact with itself
            if other_molecule_id == molecule_id
                continue
            end
            # loop over every ljsphere (atom) in the other molecule
            for other_ljsphere in molecules[other_molecule_id].ljspheres
                # compute vector between molecules in fractional coordinates
                dxf = simulation_box.c_to_f * (this_ljsphere.x - other_ljsphere.x)
                
                # simulation box has fractional coords [0, 1] by construction
                nearest_image!(dxf, (1, 1, 1))

                # converts fractional distance to cartesian distance
                dx = simulation_box.f_to_c * dxf

                r² = dx[1] * dx[1] + dx[2] * dx[2] + dx[3] * dx[3]

                if r² < R_OVERLAP_squared
                    return Inf
                elseif r² < ljforcefield.cutoffradius_squared
                    energy += lennard_jones(r²,
                        ljforcefield.σ²[this_ljsphere.atom][other_ljsphere.atom],
                        ljforcefield.ϵ[this_ljsphere.atom][other_ljsphere.atom])
                end
            end # loop over all ljspheres in other molecule
        end # loop over all other molecules
    end # loop over all ljspheres in this molecule
    return energy # units are the same as in ϵ for forcefield (Kelvin)
end

"""
Compute total guest-host interaction energy (sum over all adsorbates).
"""
function total_guest_host_vdw_energy(framework::Framework,
                                     molecules::Array{Molecule, 1},
                                     ljforcefield::LennardJonesForceField,
                                     repfactors::Tuple{Int, Int, Int})
    total_energy = 0.0
    for molecule in molecules
        total_energy += vdw_energy(framework, molecule, ljforcefield, repfactors)
    end
    return total_energy
end

"""
Compute sum of all guest-guest interaction energy from vdW interactions.
"""
function total_guest_guest_vdw_energy(molecules::Array{Molecule, 1},
                                      ljforcefield::LennardJonesForceField,
                                      simulation_box::Box)
    total_energy = 0.0
    for molecule_id = 1:length(molecules)
        total_energy += guest_guest_vdw_energy(molecule_id, molecules, ljforcefield, simulation_box)
    end
    return total_energy / 2.0 # avoid double-counting pairs
end

"""
    results = gcmc_simulation(framework, temperature, fugacity, molecule, ljforcefield;
                              n_sample_cycles=100000, n_burn_cycles=10000,
                              sample_frequency=25, verbose=false)

Runs a grand-canonical (μVT) Monte Carlo simulation of the adsorption of a molecule in a 
framework at a particular temperature and fugacity (= pressure for an ideal gas) using a
Lennard Jones force field.

A cycle is defined as max(20, number of adsorbates currently in the system) Markov chain
proposals. Current Markov chain moves implemented are particle insertion/deletion and 
translation.

# Arguments
- `framework::Framework`: the porous crystal in which we seek to simulate adsorption
- `temperature::Float64`: temperature of bulk gas phase in equilibrium with adsorbed phase
    in the porous material. units: Kelvin (K)
- `fugacity::Float64`: fugacity of bulk gas phase in equilibrium with adsorbed phase in the
    porous material. Equal to pressure for an ideal gas. units: Pascal (Pa)
- `molecule::Molecule`: a template of the adsorbate molecule of which we seek to simulate
    the adsorption
- `ljforcefield::LennardJonesForceField`: the molecular model used to describe the
    energetics of the adsorbate-adsorbate and adsorbate-host van der Waals interactions.
- `n_sample_cycles::Int`: number of cycles used for sampling
- `n_burn_cycles::Int`: number of cycles to allow the system to reach equilibrium before 
    sampling.
- `sample_frequency::Int`: during the sampling cycles, sample e.g. the number of adsorbed
    gas molecules every this number of Markov proposals.
- `verbose::Bool`: whether or not to print off information during the simulation.
"""
function gcmc_simulation(framework::Framework, temperature::Float64, fugacity::Float64,
                         molecule::Molecule, ljforcefield::LennardJonesForceField; n_sample_cycles::Int=100000,
                         n_burn_cycles::Int=10000, sample_frequency::Int=25, verbose::Bool=false)
    if verbose
        pretty_print(molecule.species, framework.name, temperature, fugacity)
    end

    const repfactors = replication_factors(framework.box, ljforcefield)
    const simulation_box = replicate_box(framework.box, repfactors)
    # TODO: assert center of mass is origin and make rotate! take optional argument to assume com is at origin?
    const molecule_template = deepcopy(molecule)

    current_energy_gg = 0.0 # only true if starting with 0 molecules TODO in adsorption isotherm dump coords from previous pressure and load them in here.
    current_energy_gh = 0.0
    gcmc_stats = GCMCstats(0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    molecules = Molecule[]

    markov_counts = MarkovCounts(zeros(Int, length(PROPOSAL_ENCODINGS)),
                                 zeros(Int, length(PROPOSAL_ENCODINGS)))

    # (n_burn_cycles + n_sample_cycles) is number of outer cycles.
    #   for each outer cycle, peform max(20, # molecules in the system) MC proposals.
    markov_chain_time = 0
    for outer_cycle = 1:(n_burn_cycles + n_sample_cycles), inner_cycle = 1:max(20, length(molecules))
        markov_chain_time += 1

        # choose proposed move randomly; keep track of proposals
        which_move = rand(1:N_PROPOSAL_TYPES)
        markov_counts.n_proposed[which_move] += 1

        if which_move == INSERTION
            insert_molecule!(molecules, simulation_box, molecule_template)

            U_gg = guest_guest_vdw_energy(length(molecules), molecules, ljforcefield, simulation_box)
            U_gh = vdw_energy(framework, molecules[end], ljforcefield, repfactors)

            # Metropolis Hastings Acceptance for Insertion
            if rand() < fugacity * simulation_box.Ω / (length(molecules) * KB *
                    temperature) * exp(-(U_gh + U_gg) / temperature)
                # accept the move, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                current_energy_gg += U_gg
                current_energy_gh += U_gh
            else
                # reject the move, remove the inserted molecule
                pop!(molecules)
            end
        elseif (which_move == DELETION) && (length(molecules) != 0)
            # propose which molecule to delete
            molecule_id = rand(1:length(molecules))

            U_gg = guest_guest_vdw_energy(molecule_id, molecules, ljforcefield,
                simulation_box)
            U_gh = vdw_energy(framework, molecules[molecule_id], ljforcefield,
                repfactors)

            # Metropolis Hastings Acceptance for Deletion
            if rand() < length(molecules) * KB * temperature / (fugacity *
                    simulation_box.Ω) * exp((U_gh + U_gg) / temperature)
                # accept the deletion, delete molecule, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                delete_molecule!(molecule_id, molecules)

                current_energy_gg -= U_gg
                current_energy_gh -= U_gh
            end
        elseif (which_move == TRANSLATION) && (length(molecules) != 0)
            # propose which molecule whose coordinates we should perturb
            molecule_id = rand(1:length(molecules))

            # energy of the molecule before it was translated
            U_gg_old = guest_guest_vdw_energy(molecule_id, molecules,
                ljforcefield, simulation_box)
            U_gh_old = vdw_energy(framework, molecules[molecule_id],
                ljforcefield, repfactors)

            old_molecule = translate_molecule!(molecules[molecule_id], simulation_box)

            # energy of the molecule after it is translated
            U_gg_new = guest_guest_vdw_energy(molecule_id, molecules,
                ljforcefield, simulation_box)
            U_gh_new = vdw_energy(framework, molecules[molecule_id],
                ljforcefield, repfactors)

            # Metropolis Hastings Acceptance for translation
            if rand() < exp(-((U_gg_new + U_gh_new) - (U_gg_old + U_gh_old))
                / temperature)
                # accept the move, adjust current energy
                markov_counts.n_accepted[which_move] += 1

                current_energy_gg += U_gg_new - U_gg_old
                current_energy_gh += U_gh_new - U_gh_old
            else
                # reject the move, reset the molecule at molecule_id
                molecules[molecule_id] = deepcopy(old_molecule)
            end
        end # which move the code executes

        # TODO remove after testing.
        for molecule in molecules
            @assert(! outside_box(molecule, simulation_box), "molecule outside box!")
        end

        # sample the current configuration
        if (outer_cycle > n_burn_cycles) && (markov_chain_time % sample_frequency == 0)
            gcmc_stats.n_samples += 1

            gcmc_stats.n += length(molecules)
            gcmc_stats.n² += length(molecules) ^ 2

            gcmc_stats.U_gh += current_energy_gh
            gcmc_stats.U_gh² += current_energy_gh ^ 2

            gcmc_stats.U_gg += current_energy_gg
            gcmc_stats.U_gg² += current_energy_gg ^ 2

            gcmc_stats.U_ggU_gh += current_energy_gg * current_energy_gh

            gcmc_stats.Un += (current_energy_gg + current_energy_gh) * length(molecules)
        end
    end # finished markov chain proposal moves

    # compute total energy, compare to `current_energy*` variables where were incremented
    total_U_gh = total_guest_host_vdw_energy(framework, molecules, ljforcefield, repfactors)
    total_U_gg = total_guest_guest_vdw_energy(molecules, ljforcefield, simulation_box)
    if ! isapprox(total_U_gh, current_energy_gh, atol=0.01)
        println("U_gh, incremented = ", current_energy_gh)
        println("U_gh, computed at end of simulation =", total_U_gh)
        error("guest-host energy incremented improperly")
    end
    if ! isapprox(total_U_gg, current_energy_gg, atol=0.01)
        println("U_gg, incremented = ", current_energy_gg)
        println("U_gg, computed at end of simulation =", total_U_gg)
        error("guest-guest energy incremented improperly")
    end

    @assert(markov_chain_time == sum(markov_counts.n_proposed))

    results = Dict{String, Any}()
    results["crystal"] = framework.name
    results["adsorbate"] = molecule.species
    results["forcefield"] = ljforcefield.name
    results["fugacity (Pa)"] = fugacity
    results["temperature (K)"] = temperature
    results["repfactors"] = repfactors

    results["# sample cycles"] = n_sample_cycles
    results["# burn cycles"] = n_burn_cycles

    results["# samples"] = gcmc_stats.n_samples

    results["# samples"] = gcmc_stats.n_samples
    results["⟨N⟩ (molecules)"] = gcmc_stats.n / gcmc_stats.n_samples
    results["⟨N⟩ (molecules/unit cell)"] = results["⟨N⟩ (molecules)"] /
        (repfactors[1] * repfactors[2] * repfactors[3])
    # (molecules/unit cell) * (mol/6.02 * 10^23 molecules) * (1000 mmol/mol) *
    #    (unit cell/framework amu) * (amu/ 1.66054 * 10^-24)
    results["⟨N⟩ (mmol/g)"] = results["⟨N⟩ (molecules/unit cell)"] * 1000 /
        (6.022140857e23 * molecular_weight(framework) * 1.66054e-24)
    results["⟨U_gg⟩ (K)"] = gcmc_stats.U_gg / gcmc_stats.n_samples
    results["⟨U_gh⟩ (K)"] = gcmc_stats.U_gh / gcmc_stats.n_samples
    results["⟨Energy⟩ (K)"] = (gcmc_stats.U_gg + gcmc_stats.U_gh) /
        gcmc_stats.n_samples
    #variances
    results["var(N)"] = (gcmc_stats.n² / gcmc_stats.n_samples) -
        (results["⟨N⟩ (molecules)"] ^ 2)
    results["Q_st (K)"] = temperature - (gcmc_stats.Un / gcmc_stats.n_samples - results["⟨Energy⟩ (K)"] * results["⟨N⟩ (molecules)"]) / results["var(N)"]
    results["var(U_gg)"] = (gcmc_stats.U_gg² / gcmc_stats.n_samples) -
        (results["⟨U_gg⟩ (K)"] ^ 2)
    results["var⟨U_gh⟩"] = (gcmc_stats.U_gh² / gcmc_stats.n_samples) -
        (results["⟨U_gh⟩ (K)"] ^ 2)
    results["var(Energy)"] = ((gcmc_stats.U_gg² + gcmc_stats.U_gh² + 2 *
        gcmc_stats.U_ggU_gh) / gcmc_stats.n_samples) -
        (results["⟨Energy⟩ (K)"] ^ 2)
    # Markov stats
    for (proposal_id, proposal_description) in PROPOSAL_ENCODINGS
        results[@sprintf("Total # %s proposals", proposal_description)] = markov_counts.n_proposed[proposal_id]
        results[@sprintf("Fraction of %s proposals accepted", proposal_description)] = markov_counts.n_accepted[proposal_id] / markov_counts.n_proposed[proposal_id]
    end

    if verbose
        print_results(results)
    end

    return results
end # gcmc_simulation

function print_results(results::Dict)
    @printf("GCMC simulation of %s in %s at %f K and %f Pa = %f bar fugacity.\n\n",
            results["adsorbate"], results["crystal"], results["temperature (K)"],
            results["fugacity (Pa)"], results["fugacity (Pa)"] / 100000.0)

    @printf("Unit cell replication factors: %d %d %d\n\n", results["repfactors"][1],
                                                         results["repfactors"][2],
                                                         results["repfactors"][3])
    # Markov stats
    for (proposal_id, proposal_description) in PROPOSAL_ENCODINGS
        for key in [@sprintf("Total # %s proposals", proposal_description),
                    @sprintf("Fraction of %s proposals accepted", proposal_description)]
            println(key * ": ", results[key])
        end
    end

    println("")
    for key in ["# sample cycles", "# burn cycles", "# samples"]
        println(key * ": ", results[key])
    end


    println("")
    for key in ["⟨N⟩ (molecules)", "⟨N⟩ (molecules/unit cell)",
                "⟨N⟩ (mmol/g)", "⟨U_gg⟩ (K)", "⟨U_gh⟩ (K)", "⟨Energy⟩ (K)",
                "var(N)", "var(U_gg)", "var⟨U_gh⟩", "var(Energy)"]
        println(key * ": ", results[key])
    end

    @printf("Q_st (K) = %f = %f kJ/mol\n", results["Q_st (K)"], results["Q_st (K)"] * 8.314 / 1000.0)
    return
end

function pretty_print(adsorbate::Symbol, frameworkname::String, temperature::Float64, fugacity::Float64)
    print("Simulating adsorption of ")
    print_with_color(:green, adsorbate)
    print(" in ")
    print_with_color(:green, frameworkname)
    print(" at ")
    print_with_color(:green, @sprintf("%f K", temperature))
    print(" and ")
    print_with_color(:green, @sprintf("%f Pa", fugacity))
    println(" (fugacity).")
end
