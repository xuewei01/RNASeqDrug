options(stringsAsFactors=FALSE)

require(PharmacoGx) || stop("Library PharmacoGx is not available!")
require(Biobase) || stop("Library Biobase is not available!")
require(calibrate) || stop("Library calibrate is not available!")
require(stringr) || stop("Library stringr is not available!")
require(gdata) || stop("Library gdata is not available!")
require(genefu) || stop("Library genefu is not available!")
require(xtable) || stop("Library xtable is not available!")

options(stringsAsFactors=FALSE)

effect.size.cut.off <- 0.55
pvalue.cut.off <- 0.05
source(file.path("code","foo_PreValidation.R"))

if(!exists("ccle.genes.fpkm")){
  path.training.data <- "data/training_ccle_gdsc.RData"
  load(path.training.data, verbose=TRUE)
  if("gdsc.drug.sensitivity" %in% ls()) {
    training.type <-"CCLE_GDSC"
  } else {
    training.type <-"CCLE"
  }
  path.diagrams<- "result/auc_recomputed_ccle_gdsc"
  tissue <- "breast"
  model.method <- "glm"
  glm.family <- "gaussian" 
  effect.size <- "cindex" #c("r.squared", "cindex")
  path.data <- "data"
  path.code <- file.path("code")
  path.result <- file.path("result")
  adjustment.method <- "fdr"
  source(file.path(path.code, "foo.R"))
}
sensitivity.type <- phenotype <- "auc_recomputed"
RNA_seq.normalize <- TRUE
genes <- colnames(ccle.genes.fpkm)
isoforms <- colnames(ccle.isoforms.fpkm)

load(file.path(path.data, "PSets/GRAY_hs.RData"))
gray.drug.sensitivity <- t(PharmacoGx::summarizeSensitivityProfiles(pSet=GRAY, sensitivity.measure=sensitivity.type))
drugs <- intersect(colnames(ccle.drug.sensitivity), colnames(gray.drug.sensitivity))

gray.genes.fpkm <- t(Biobase::exprs(PharmacoGx::summarizeMolecularProfiles(pSet=GRAY, mDataType="rnaseq", features=genes, fill.missing=FALSE)))
gray.isoforms.fpkm <- t(Biobase::exprs(PharmacoGx::summarizeMolecularProfiles(pSet=GRAY, mDataType="isoforms", features=isoforms, fill.missing=FALSE)))
gray.isoforms.fpkm[which(is.na(gray.isoforms.fpkm))] <- 0
if(RNA_seq.normalize == TRUE) {
  gray.genes.fpkm <- log2(gray.genes.fpkm + 1)
  gray.isoforms.fpkm <- log2(gray.isoforms.fpkm + 1)
}
gray.cells <- intersect(rownames(gray.drug.sensitivity), rownames(gray.genes.fpkm))
gray.drug.sensitivity <- gray.drug.sensitivity[gray.cells, , drop=FALSE]
gray.genes.fpkm <- gray.genes.fpkm[gray.cells, , drop=FALSE]
gray.isoforms.fpkm <- gray.isoforms.fpkm[gray.cells, , drop=FALSE]

load(file.path(path.diagrams, "all.biomarkers.RData"))
max.bio.no <- max(sapply(all.biomarkers, function(x){nrow(x)}))
breast.biomarkers <- fnValidation(top.significant.biomarkers=all.biomarkers, validation.cut.off=max.bio.no, validation.method=effect.size)
save(breast.biomarkers, file=file.path(path.diagrams, "breast.biomarkers.RData"))

validated.biomarkers <- breast.biomarkers
for(drug in drugs) {
  validated.biomarkers[[drug]] <- validated.biomarkers[[drug]][which(validated.biomarkers[[drug]]$validation.stat == "validated"),]
}

breast <- all <- res.validated <- breast.validated.percent <- all.validated.percent <- validated.no <- NULL
for(drug in drugs) {
  temp <- validated.biomarkers[[drug]]
  if(length(xx) > 0) {
    xx <- paste(t(apply(temp, 1, function(x){sprintf("%s(%s)", x["symbol"], x["type"])}) ), collapse="_")
    res.validated <-  c(res.validated, xx)
  } else {
    res.validated <-  c(res.validated, "")
  }
  validated <- unlist(str_split(xx, pattern="_"))
  if(all(validated == "")){lv <- 0} else{lv <- length(validated)}
  validated.no <- c(validated.no, lv)
  all.validated.percent <- c(all.validated.percent, round(lv/nrow(all.biomarkers[[drug]]), digits=2))
  all <- c(all, length(which(rownames(all.biomarkers[[drug]]) != "NA")))
  
  if(!is.null(breast.biomarkers[[drug]])){
    breast.validated.percent <- c(breast.validated.percent, round(lv/nrow(breast.biomarkers[[drug]]), digits=2))
    breast <- c(breast, nrow(breast.biomarkers[[drug]]))
  }else{
    breast.validated.percent <- c(breast.validated.percent, 0)
    breast <- c(breast, 0)
  }
}
write.csv(cbind("drug"=drugs,
                "validated"=res.validated,
                "validated no"=validated.no,
                "biomarkers no"=all,
                "ratio from all"=all.validated.percent,
                "breast significant biomarkers no"=breast,
                "ratio from breast biomarkers"=breast.validated.percent), file=file.path(path.diagrams, "gray_validation_rate.csv"))
##Stringtie estimated expressions are not comparable to those from cufflinks
#if(!"GTex.BR" %in% ls()){
#  load("data/GTex_BR.RData", verbose=T)
#}
#fnGtex(validation.method=effect.size)
#fnGtex(all.biomarkers=biomarkers, validation.method=validation.method)

source("code/foo_training.R")
for(drug in drugs) {
  if(nrow(validated.biomarkers[[drug]]) > 0){
    tt <- which(validated.biomarkers[[drug]][,"transcript.id"]!= "")
    xx <- validated.biomarkers[[drug]][tt, ]
    validated.biomarkers[[drug]][which(validated.biomarkers[[drug]][,"transcript.id"]== ""), "gray.specificity"] <- "gene.specific"
    if(!is.null(xx)){
      p.values.isoform <- p.values.gene <- NULL
      for(i in 1:nrow(xx)) {
        M0 <- fnCreateNullModel(drug=drug, assay="gray")
        M2 <- fnCreateGeneModel(drug=drug, nullModel=M0, data=gray.genes.fpkm[ ,xx[i, "gene.id"]])
        M3B <- fnCreateGeneModel(drug=drug, nullModel=M0, data=gray.isoforms.fpkm[ ,xx[i, "transcript.id"]])
        results <- fnRunbootstrap(models=list("M2"=M2, "M3B"=M3B), effect.size=effect.size)
        if(length(results[["M2"]])>0 && length(results[["M3B"]])>0){
          pp <- wilcox.test(results[["M3B"]], results[["M2"]], paired=TRUE, alternative="greater")$p.value
          p.values.isoform <- c(p.values.isoform, ifelse((pp * 2)<1, pp * 2, 1))
          pp <- wilcox.test(results[["M3B"]], results[["M2"]], paired=TRUE, alternative="less")$p.value
          p.values.gene <- c(p.values.gene, ifelse((pp * 2)<1, pp * 2, 1))
        }
        if(length(results[["M2"]])>0 && length(results[["M3B"]])==0){
          p.values.isoform <- c(p.values.isoform , 1)
          p.values.gene <- c(p.values.gene, 0.00001)
        }
        if(length(results[["M2"]])==0 && length(results[["M3B"]])>0){
          p.values.isoform <- c(p.values.isoform, 0.00001)
          p.values.gene <- c(p.values.gene, 1)
        }
        if(length(results[["M2"]])==0 && length(results[["M3B"]])==0){
          p.values.isoform <- c(p.values.isoform, 1)
          p.values.gene <- c(p.values.gene, 1)
        }
      }
      names(p.values.isoform) <- names(p.values.gene) <- rownames(xx)
      validated.biomarkers[[drug]][tt, "gray.specificity"] <- "common"
      for( i in names(p.values.isoform)){
        if(p.values.isoform[i] < 0.05) {
          validated.biomarkers[[drug]][i, "gray.specificity"] <- "isoform.specific"
        }else if(p.values.gene[i] < 0.05) {
          validated.biomarkers[[drug]][i, "gray.specificity"] <- "gene.specific"
        }
        validated.biomarkers[[drug]][i, "gray.isoform.specific.test.pvalue"] <- p.values.isoform[i]
        validated.biomarkers[[drug]][i, "gray.gene.specific.test.pvalue"] <- p.values.gene[i]
      }
    }
  }
}

save(validated.biomarkers, file=file.path(path.diagrams, "validated.biomarkers.gray.RData"))
validated.biomarkers.fdr <- list()
for(drug in names(validated.biomarkers)) {
  validated.biomarkers.fdr[[drug]] <- validated.biomarkers[[drug]]
  validated.biomarkers.fdr[[drug]][,"gray.fdr"] <- p.adjust(validated.biomarkers.fdr[[drug]][,"gray.pvalue"], method="fdr")
}
for(drug in names(validated.biomarkers.fdr)) {
  message(sprintf("%s : %s", drug, length(which(validated.biomarkers.fdr[[drug]][,"gray.fdr"]< 0.05))))
  validated.biomarkers.fdr[[drug]] <- validated.biomarkers.fdr[[drug]][which(validated.biomarkers.fdr[[drug]][,"gray.fdr"]< 0.05),]
}
sapply(validated.biomarkers, nrow)
save(validated.biomarkers.fdr, file=file.path(path.diagrams, "validated.biomarkers.gray.fdr.RData"))

