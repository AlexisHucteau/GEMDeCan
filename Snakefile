#######################################
# Julien Pernet 2020 for Pancaldi lab - CRCT Team 21 - INSERM
# This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#######################################

from os.path import basename
from os.path import abspath
from re import sub
import csv

configfile: "config.yaml"

##########################
####     PARAMETERS     ####
#########################

# Define paths
OUTbcl = config["Output_Directory"] + "/bcl2raw"
OUTfastqc = config["Output_Directory"] + "/fastqc_raw"
OUTfastqc2 = config["Output_Directory"] + "/fastqc_after_trimming"
OUTmultiqc = config["Output_Directory"] + "/multiqc_raw"
OUTmultiqc2 = config["Output_Directory"] + "/multiqc_after_trimming"
OUTcut = config["Output_Directory"] + "/data_after_trimming"
QUANTIF = config["Output_Directory"] + "/Quantification"

SIG_name = ""

SNAKEMAKE_WRAPPERS_VERSION = "0.70.0"

##########################
#### Exceptions handling ####
#########################

def exit_error(message):
    exit("ERROR: Exiting Snakemake procedure due to missing \"{}\" parameter in the config.yaml file.".format(message))

if config["Do_deconv"] == "yes":

    if config["Signatures"] is None:
        exit_error("Signatures")

if config["Do_rnaseq"] == "yes":

    if config["Trim_with"] is None:
        exit_error("Trim_with")

    if config["Quantification_with"] is None:
        exit_error("Quantification_with")

    if config["Quantification_with"] == "STAR":
        if config["GTF"] is None:
            exit_error("GTF")
        if config["Genome"] is None:
            exit_error("Genome")

    if config["Index_rnaseq"] is None and config["Compute_index"] != "yes":
        exit_error("Index_rnaseq")

    if config["Convert_bcl2fastq"] is None:
        exit_error("Convert_bcl2fastq")

    if config["Convert_bcl2fastq"] == "yes" and config["Sample_Sheet"] is None:
        exit_error("Sample_Sheet")

    if config["Convert_bcl2fastq"] == "no" and config["Samples"] is None:
        exit_error("Samples")

    if config["Convert_bcl2fastq"] == "yes":
        # extract samples names from Illumina Sample Sheet.
        file_out = basename(config["Sample_Sheet"])
        file_out = sub(".csv", "", file_out, 1)
        file_out = "Samples_" + file_out + ".txt"
        print(file_out)
        with open(config["Sample_Sheet"], "r") as f_in, open(file_out, "w") as f_out:
            for skip in range(18):
                next(f_in)
            reader = csv.reader(f_in, delimiter=',')
            SAMPLES = list(set([row[2] for row in reader]))
            f_out.write(SAMPLES[0])
            for item in SAMPLES[1:]:
                    f_out.write('\n{}'.format(item))

    ## else if Do_rnaseq = yes and Convert_bcl2fastq = no, Path to file of Samples' names is required
    else:
        SAMPLES = list(open(config["Samples"]).read().splitlines())


##########################
####       OUTPUTS          ####
#########################
if config["Do_deconv"] == "yes" and config["Do_rnaseq"] == "yes":
    rule all:
        input:
            OUTmultiqc + "/multiqc_report.html",
            OUTmultiqc2 + "/multiqc_report.html",
            config["Output_Directory"] + "/deconvolution.txt",
            directory(config["Output_Directory"] + "/HTML_REPORT")

elif config["Do_deconv"] == "yes" and config["Do_rnaseq"] == "no":
    rule all:
        input:
            config["Output_Directory"] + "/deconvolution.txt",
            directory(config["Output_Directory"] + "/HTML_REPORT")

elif config["Do_deconv"] == "no" and config["Do_rnaseq"] == "yes":
    rule all:
        input:
            OUTmultiqc + "/multiqc_report.html",
            OUTmultiqc2 + "/multiqc_report.html",
            config["Output_Directory"] + "/TPM.txt"

########################
####### RNA-SEQ #######
#######################

if config["Do_rnaseq"] == "yes":

    ## Converts base call (.BCL) files into FASTQ
    if config["Convert_bcl2fastq"] == "yes":
        rule bcl2fastq:
            input:
                INDIR = config["Input"],
                SHEET = config["Sample_Sheet"]
            output:
                OUTbcl + "/Reports/html/index.html"
            params:
                OUTbcl
            message:
                "Converting BCL2 Illumina files to fastQ"
            conda:
                "Tools/bcl2fastq.yaml"
            threads: config["THREADS"]
            singularity:
                "docker://continuumio/miniconda3:4.8.2"
            shell:
                """
                bcl2fastq -w {threads} -R {input.INDIR} -o {params} --sample-sheet {input.SHEET} --no-lane-splitting
                rm {params}/Undetermined*
                """

        rule rename_raw:
            input:
                OUTbcl + "/Reports/html/index.html"
            output:
                expand(OUTbcl + "/{samples}_R1.fastq.gz", samples= SAMPLES),
                expand(OUTbcl + "/{samples}_R2.fastq.gz", samples= SAMPLES)
            params:
                OUTbcl
            conda:
                "Tools/rename.yaml"
            shell:
                """
                rename 's/S[0-9]+_(R1|R2)_001/$1/g' {params}/*.fastq.gz
                """

    # declare QCINPUT for next processing
    if  config["Convert_bcl2fastq"] == "yes":
        QCINPUT = OUTbcl
    else:
        QCINPUT = config["Input"]

    ## Quality control for raw fastq data
    rule fastqc1:
        input:
            r1 = QCINPUT + "/{samples}_R1.fastq.gz",
            r2 = QCINPUT + "/{samples}_R2.fastq.gz"
        output:
            zip1 = OUTfastqc + "/{samples}_R1_fastqc.zip",
            zip2 = OUTfastqc + "/{samples}_R2_fastqc.zip"
        threads: 
            config["THREADS"]
        benchmark:
            "benchmarks/benchmark.fastqc1_{samples}.txt"
        message:
            "Quality control before trimming"
        params:
            OUTfastqc
        conda:
            "Tools/fastqc.yaml"
        shell:
            "fastqc -t {threads} --quiet --outdir {params} {input.r1} {input.r2}"

    rule multiqc1:
        input:
            expand(OUTfastqc + "/{samples}_R2_fastqc.zip", samples= SAMPLES)
            # input is only usefull for the directory here, using R2 to make sure all samples ran into fastqc
        benchmark:
            "benchmarks/benchmark.multiqc1.txt"
        output:
            OUTmultiqc + "/multiqc_report.html"
        wrapper:
            SNAKEMAKE_WRAPPERS_VERSION + "/bio/multiqc"

    if config["Trim_with"] == "Trimmomatic":
        ## Read trimming by Trimmomatic (Paired-End)
        rule Trimmomatic:
            input:
                r1 = QCINPUT + "/{samples}_R1.fastq.gz",
                r2 = QCINPUT + "/{samples}_R2.fastq.gz"
            output:
                r1 = OUTcut + "/{samples}_R1.fastq.gz",
                r1_unpaired = OUTcut + "/{samples}_R1.unpaired.fastq.gz",
                r2 = OUTcut + "/{samples}_R2.fastq.gz",
                r2_unpaired = OUTcut + "/{samples}_R2.unpaired.fastq.gz"
            threads: config["THREADS"]
            message:
                "Trimming using Trimmomatic"
            benchmark:
                "benchmarks/benchmark.trimmomatic_{samples}.txt"
            params:
                trimmer = ["TRAILING:20", "LEADING:20", "MINLEN:36", "CROP:10000", "ILLUMINACLIP:" + config["Adapter"] + ":2:30:10"],
                extra = "-phred33"
            wrapper:
                SNAKEMAKE_WRAPPERS_VERSION + "/bio/trimmomatic/pe"

    elif config["Trim_with"] == "Trimgalore":
        ## Read trimming by Trim-galore (Paired-end)
        rule trimgalore:
            input:
                QCINPUT + "/{samples}_R1.fastq.gz",
                QCINPUT + "/{samples}_R2.fastq.gz"
            output:
                OUTcut + "/{samples}_R1_val_1.fq.gz",
                OUTcut + "/{samples}_R1.fastq.gz_trimming_report.txt",
                OUTcut + "/{samples}_R2_val_2.fq.gz",
                OUTcut + "/{samples}_R2.fastq.gz_trimming_report.txt"
            params:
                extra= '--phred33 --illumina --paired --quality 20 --length 36'
            threads: config["THREADS"]
            message:
                "Trimming using Trim-Galore"
            benchmark:
                "benchmarks/benchmark.trimgalore_{samples}.txt"
            wrapper:
                SNAKEMAKE_WRAPPERS_VERSION + "/bio/trim_galore/pe"

        rule rename:
            input:
                R1 = OUTcut + "/{samples}_R1_val_1.fq.gz",
                R2 = OUTcut + "/{samples}_R2_val_2.fq.gz"
            output:
                R1out = OUTcut + "/{samples}_R1.fastq.gz",
                R2out = OUTcut + "/{samples}_R2.fastq.gz"
            benchmark:
                "benchmarks/benchmark.rename_{samples}.txt"
            shell:
                """
                mv -f {input.R1} {output.R1out}
                mv -f {input.R2} {output.R2out}
                """

    ## Quality control after trimming
    rule fastqc2:
        input:
            r1 = OUTcut + "/{samples}_R1.fastq.gz",
            r2 = OUTcut + "/{samples}_R2.fastq.gz"
        output:
            zip1 = OUTfastqc2 + "/{samples}_R1_fastqc.zip",
            zip2 = OUTfastqc2 + "/{samples}_R2_fastqc.zip"
        threads: 
            config["THREADS"]
        message:
            "Quality control after trimming"
        benchmark:
            "benchmarks/benchmark.fastqc2_{samples}.txt"
        params:
            OUTfastqc2
        conda:
            "Tools/fastqc.yaml"
        shell:
            "fastqc -t {threads} --quiet --outdir {params} {input.r1} {input.r2}"

    rule multiqc2:
        input:
            expand(OUTfastqc2 + "/{samples}_R2_fastqc.zip", samples= SAMPLES)
        benchmark:
            "benchmarks/benchmark.multiqc2.txt"
        output:
            OUTmultiqc2 + "/multiqc_report.html"
        wrapper:
            SNAKEMAKE_WRAPPERS_VERSION + "/bio/multiqc"

    # Quantification
    if config["Quantification_with"] == "kallisto":
        if config["Compute_index"] == "yes":
            rule kallisto_index:
                input:
                    config["CDNA"]
                output:
                    "data/genome/kallisto_transcript.idx"
                message:
                    "Building Kallisto index"
                conda:
                    "Tools/kallisto.yaml"
                shell:
                    "kallisto index -i {output} {input}"
            index = rules.kallisto_index.output
        else:
            index = config["Index_rnaseq"]
        
        rule kallisto:
            input:
                R1 = OUTcut + "/{samples}_R1.fastq.gz",
                R2 = OUTcut + "/{samples}_R2.fastq.gz",
                INDEX = index
            threads: 
                config["THREADS"]
            output:
                QUANTIF + "/{samples}/abundance.tsv",
                QUANTIF + "/{samples}/abundance.h5"
            params:
                OUTDIRE = QUANTIF + "/{samples}"
            message:
                "Quantification with Kallisto"
            benchmark:
                "benchmarks/benchmark.kallisto_{samples}.txt"
            conda:
                "Tools/kallisto.yaml"
            singularity:
                "docker://continuumio/miniconda3:4.8.2"
            shell:
                "kallisto quant -t {threads} -i {input.INDEX} -b 30 "
                "-o {params.OUTDIRE} "
                "{input.R1} {input.R2}"

        rule kallisto_quant:
            input:
                expand(QUANTIF + "/{samples}/abundance.h5", samples= SAMPLES)
            output:
                config["Output_Directory"] + "/TPM.txt"
            params:
                QUANTIF,
                SAMPLES
            benchmark:
                "benchmarks/benchmark.quant_to_gene.txt"
            conda:
                "Tools/quantif.yaml"
            singularity:
                "docker://continuumio/miniconda3:4.8.2"
            script:
                "Tools/quant_for_kallisto.R"

    elif config["Quantification_with"] == "salmon":
        if config["Compute_index"] == "yes":
            rule salmon_index:
                input:
                    CDNA = config["CDNA"],
                    GENOME = config["Genome"]
                output:
                    directory("data/genome/salmon_index")
                threads:
                    config["THREADS"]
                params:
                    "data/genome/salmon_index"
                message:
                    "Building Salmon index"
                benchmark:
                    "benchmarks/benchmark.salmon_index.txt"
                conda:
                    "Tools/salmon.yaml"
                shell:
                    "bash Tools/compute_index_salmon.sh {input.GENOME} {input.CDNA} {threads} {params}"
            index = rules.salmon_index.output
        else:
            index = config["Index_rnaseq"]

        rule salmon:
            input:
                r1 = OUTcut + "/{samples}_R1.fastq.gz",
                r2 = OUTcut + "/{samples}_R2.fastq.gz",
                INDEX = index
            output:
                QUANTIF + "/{samples}/quant.sf"
            params:
                DIR = QUANTIF + "/{samples}",
                libtype ="A",
                extra=" --validateMappings"
            threads: config["THREADS"]
            message:
                "Quantification with Salmon"
            benchmark:
                "benchmarks/benchmark.salmon_{samples}.txt"
            conda:
                "Tools/salmon.yaml"
            singularity:
                "docker://continuumio/miniconda3:4.8.2"
            shell:
                "salmon quant -i {input.INDEX} -l {params.libtype} "
                "-1 {input.r1} -2 {input.r2} "
                "-o {params.DIR} "
                "-p {threads} --validateMappings"

        rule salmon_quant:
            input:
                expand(QUANTIF + "/{samples}/quant.sf", samples= SAMPLES)
            output:
                config["Output_Directory"] + "/TPM.txt"
            params:
                QUANTIF,
                SAMPLES
            benchmark:
                "benchmarks/benchmark.quant_to_gene.txt"
            conda:
                "Tools/quantif.yaml"
            singularity:
                "docker://continuumio/miniconda3:4.8.2"
            script:
                "Tools/quant_for_salmon.R"

    elif config["Quantification_with"] == "STAR":
        if config["Compute_index"] == "yes":
            rule star_index:
                input:
                    GENOME = config["Genome"],
                    GTF = config["GTF"]
                output:
                    directory("data/genome/star")
                threads:
                    config["THREADS"]
                benchmark:
                    "benchmark/star_index.txt"
                message:
                    "Computing STAR index"
                conda:
                    "Tools/star.yaml"
                shell:
                    "STAR --runThreadN {threads} --runMode genomeGenerate "
                    "--genomeDir {output} --genomeFastaFiles {input.GENOME} "
                    "--sjdbGTFfile {input.GTF}"
            index = rules.star_index.output
        else:
            index =  config["Index_rnaseq"]
 
        rule star:
            input:
                fq1 = OUTcut + "/{samples}_R1.fastq.gz",
                fq2 = OUTcut + "/{samples}_R2.fastq.gz",
                GENOMEdir =index
            output:
                config["Output_Directory"] + "/star/{samples}/Aligned.toTranscriptome.out.bam"
            params:
                OUT = config["Output_Directory"] + "/star/{samples}/",
                GTF = config["GTF"]
            threads:
                config["THREADS"]
            benchmark:
                "benchmarks/star_{samples}.txt"
            conda:
                "Tools/star.yaml"
            shell:
                "STAR "
                "--runThreadN {threads} "
                "--runMode alignReads "
                "--readFilesCommand zcat "
                "--outSAMtype BAM SortedByCoordinate "
                "--quantMode TranscriptomeSAM "
                "--quantTranscriptomeBan IndelSoftclipSingleend "
                "--outFileNamePrefix {params.OUT} "
                "--genomeDir {input.GENOMEdir} "
                "--sjdbGTFfile {params.GTF} "
                "--readFilesIn {input.fq1} {input.fq2}"

        rule RSEM_ref:
            input:
                config["GTF"]
            output:
                "data/rsem/gen.seq"
            params:
                GEN = config["Genome"],
                REF = "data/rsem/gen"
            threads:
                config["THREADS"]
            conda:
                "Tools/rsem.yaml"
            shell:
                "rsem-prepare-reference "
                "-p {threads} "
                "--gtf {input} "
                "{params.GEN} "
                "{params.REF}"

        rule RSEM:
            input:
                BAM = config["Output_Directory"] + "/star/{samples}/Aligned.toTranscriptome.out.bam",
                PREV = rules.RSEM_ref.output
            output:
                config["Output_Directory"] + "/rsem/{samples}.genes.results"
            params:
                OUT = config["Output_Directory"] + "/rsem/{samples}",
                REF = "data/rsem/gen"
            threads:
                config["THREADS"]
            benchmark:
                "benchmarks/rsem_{samples}.txt"
            conda:
                "Tools/rsem.yaml"
            shell:
                "rsem-calculate-expression "
                "-p {threads} "
                "--paired-end --alignments  "
                "--estimate-rspd "
                "--no-bam-output "
                "--strandedness reverse "
                "{input.BAM} "
                "{params.REF} "
                "{params.OUT}"

        rule star_quant:
            input:
                expand(config["Output_Directory"] + "/rsem/{samples}.genes.results", samples= SAMPLES)
            output:
                config["Output_Directory"] + "/TPM.txt"
            params:
                config["Output_Directory"] + "/rsem",
                SAMPLES
            conda:
                "Tools/quantif.yaml"
            script:
                "Tools/quant_for_star.R"

##########################
#### DECONVOLUTION ####
#########################

if config["Do_deconv"] == "yes":
    if config["Do_rnaseq"] == "yes":
        DECONV_INPUT = config["Output_Directory"] + "/TPM.txt"
    else:
        DECONV_INPUT = config["Input"]

    rule deconvolution:
        input:
            DECONV_INPUT
        output:
            config["Output_Directory"] + "/deconvolution.txt"
        params:
            config["Signatures"]
        message:
            "Running deconvolution"
        threads:
            config["THREADS"]
        benchmark:
            "benchmarks/benchmark.deconvolution.txt"
        conda:
            "Tools/deconvolution.yaml"
        singularity:
            "docker://continuumio/miniconda3:4.8.2"
        shell:
            "Tools/deconvolution.R {input} {output} {params} {threads}"

    rule report:
        input:
            rules.deconvolution.output
        output:
            directory(config["Output_Directory"] + "/HTML_REPORT")
        params:
            abspath(rules.deconvolution.output[0])
        message:
            "Generating report"
        conda:
            "Tools/analyse.yaml"
        shell:
            "Rscript --vanilla -e \"rmarkdown::render('Tools/analyses.R', output_dir='{output}')\" {params}"
