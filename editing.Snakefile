# @author: Vivek Bhardwaj (@vivekbhr)
# @date: Nov 5, 2016
# @desc: Snakemake pipeline for RNA editing detection following variant calling (human genome hg38)
#
# Usage: snakemake --snakefile Snakefile.editing --jobs 2 -c "SlurmEasy -t {threads} -n {rule}"
## needs: bedtools, crossmap, chain files

from os.path import join, dirname
# Globals ---------------------------------------------------------------------

GENOME = config['genome_fasta']
REDIPORTAL = "http://srv00.recas.ba.infn.it/webshare/rediportalDownload/table1_full.txt.gz"
DBSNP = "ftp://ftp.ncbi.nih.gov/snp/organisms/human_9606_b146_GRCh38p2/VCF/00-common_all.vcf.gz"
HEKSNP = "http://bioinformatics.psb.ugent.be/downloads/genomeview/hek293/hg18/CG_8lines.vcf.gz"
THREADS = 20
# Full path to output folder.
OUTPUT_DIR = config['outdir'] #"editing_polyA-plus"
#VARCALL = config['varcall_outdir'] #"editing_polyA-plus"

if not os.path.exists(OUTPUT_DIR):
    os.makedirs(OUTPUT_DIR)

# A snakemake regular expression matching the forward mate FASTQ files.
SAMPLES, = glob_wildcards(join(OUTPUT_DIR, 'snps_{sample,[^/]+}.vcf'))
#SAMPLES = ['ctrl','test']
print(SAMPLES)

rule all:
    input:
        join(OUTPUT_DIR, 'known_editing_sites_GRCh38.bed'),
        #join(OUTPUT_DIR, 'combined_vars_all.vcf'),
        expand(join(OUTPUT_DIR, '{sample}_snps_dbsnp_filtered.vcf'), sample = SAMPLES),
        expand(join(OUTPUT_DIR, '{sample}_snps_all_filtered.vcf'), sample = SAMPLES),
        join(OUTPUT_DIR, 'testUniq_filtered.vcf'),
        join(OUTPUT_DIR, 'controlUniq_filtered.vcf'),
        join(OUTPUT_DIR, 'controlUniq_filtered_known_edits.vcf'),
        join(OUTPUT_DIR, 'testUniq_filtered_known_edits.vcf')


# merge variants from our varcall
#rule gatk_varmerge:
#    input: 'varcall_polyA-minus'
#    output: join(OUTPUT_DIR, 'combined_vars_all.vcf')
#    log:
#        join(OUTPUT_DIR, 'combinedVars.log')
#    threads:
#        THREADS
#    run:
        # Write stderr and stdout to the log file.
#        shell('sh gatk_combinevar.sh {input} {OUTPUT_DIR}')

# download and unpack known sites from REDIPortal
rule get_known_sites:
    output: join(OUTPUT_DIR, 'known_editing_sites_GRCh38.txt')
    run:
        shell('wget {REDIPORTAL};'
            'gunzip table1_full.txt.gz;'
            'mv table1_full.txt editing/known_editing_sites_GRCh38.txt;')

rule makebed:
    input: rules.get_known_sites.output
    output: join(OUTPUT_DIR, 'known_editing_sites_GRCh38.bed')
    shell:
        'awk \'OFS="\\t" {{print $1,$2,$2+1,$9,$5}}\' {OUTPUT_DIR}/known_editing_sites_GRCh38.txt | sed \'s/chr//g\' > {OUTPUT_DIR}/known_editing_sites_GRCh38.bed'

# Download and prepare SNPs fom DBSNP and HEK SNP database
rule get_dbSNP:
    output: join(OUTPUT_DIR, 'dbSNP_all.vcf')
    run:
        shell('wget {DBSNP};'
              'gunzip 00-common_all.vcf.gz;'
              'mv 00-common_all.vcf {OUTPUT_DIR}/dbSNP_all.vcf;')

rule get_hekSNP:
    output: join(OUTPUT_DIR, 'hekSNP_all.vcf')
    run:
        shell('wget {HEKSNP};'
              'gunzip CG_8lines.vcf.gz;'
              'mv CG_8lines.vcf {OUTPUT_DIR}/hekSNP_all.vcf;')

rule liftover_hekSNP:
    input:  join(OUTPUT_DIR, 'hekSNP_all.vcf')
    output: join(OUTPUT_DIR, 'hekSNP_all_hg38.bed')
    run:
        shell('sed -e \'s/chr//\' {input} | awk \'{OFS="\t"; if (!/^#/){print $1,$2-1,$2,$4"/"$5,"+"}}\' > hekSNP_all.bed;'
              'while read ucsc ens; do sed -i "s/$ucsc/$ens/g" hg18ToHg38.over.chain; done < /data/repository/organisms/GRCh37_ensembl/UCSC.map;'
              'CrossMap.py bed hg18ToHg38.over.chain hekSNP_all.bed {output}')

# Filter SNPs
rule filter_dbSNP:
    input:
        dbsnp=rules.get_dbSNP.output,
        vcf=join(OUTPUT_DIR,'snps_{sample}.vcf')

    output: join(OUTPUT_DIR, '{sample}_snps_dbsnp_filtered.vcf')
    run:
        shell('bedtools intersect -v -a {input.vcf} -b {input.dbsnp} -header > {output}')

rule filter_hekSNP:
    input:
        heksnp=rules.liftover_hekSNP.output,
        vcf=rules.filter_dbSNP.output

    output: join(OUTPUT_DIR, '{sample}_snps_all_filtered.vcf')
    run:
        shell('bedtools intersect -v -a {input.vcf} -b {input.heksnp} -header > {output}')

# Select only varients which are in test but not in control vcf
rule filter_ctrl_snps:
    input:
        ctrl=join(OUTPUT_DIR, 'ctrl_snps_all_filtered.vcf'),
        test=join(OUTPUT_DIR, 'test_snps_all_filtered.vcf')

    output:
        ctrl=join(OUTPUT_DIR, 'controlUniq_filtered.vcf'),
        test=join(OUTPUT_DIR, 'testUniq_filtered.vcf')
    run:
        shell('bedtools intersect -v -a {input.test} -b {input.ctrl} -header > {output.test};'
              'bedtools intersect -v -a {input.ctrl} -b {input.test} -header > {output.ctrl};')

# Intersect with known Editing sites
rule intersect_known_edits:
    input:
        ctrl=join(OUTPUT_DIR, 'controlUniq_filtered.vcf'),
        test=join(OUTPUT_DIR, 'testUniq_filtered.vcf'),
        known=rules.makebed.output

    output:
        ctrl=join(OUTPUT_DIR, 'controlUniq_filtered_known_edits.vcf'),
        test=join(OUTPUT_DIR, 'testUniq_filtered_known_edits.vcf')

    run:
        shell('bedtools intersect -a {input.ctrl} -b {input.known} -header > {output.ctrl};'
              'bedtools intersect -a {input.test} -b {input.known} -header > {output.test};')
